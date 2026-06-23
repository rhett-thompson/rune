package main

import "core:encoding/json"
import "core:math"
import "rune:ecs"
import "rune:input"
import "rune:jsonutil"

First_Person_Settings :: struct {
	move_speed:        f32,
	sprint_multiplier: f32,
	mouse_sensitivity: f32,
}

first_person_settings :: proc(world: ^ecs.World, entity: ecs.Entity) -> (First_Person_Settings, bool) {
	data, found := ecs.get_component(world, entity, "FirstPersonController")
	if !found { return {}, false }
	object, ok := data.(json.Object)
	if !ok { return {}, false }

	settings := First_Person_Settings{move_speed = 5, sprint_multiplier = 1.8, mouse_sensitivity = 0.15}
	if value, exists := object["move_speed"]; exists {
		settings.move_speed, ok = jsonutil.number(value)
		if !ok || settings.move_speed <= 0 { return {}, false }
	}
	if value, exists := object["sprint_multiplier"]; exists {
		settings.sprint_multiplier, ok = jsonutil.number(value)
		if !ok || settings.sprint_multiplier <= 0 { return {}, false }
	}
	if value, exists := object["mouse_sensitivity"]; exists {
		settings.mouse_sensitivity, ok = jsonutil.number(value)
		if !ok || settings.mouse_sensitivity <= 0 { return {}, false }
	}
	return settings, true
}

first_person_controller_system :: proc(world: ^ecs.World, entity: ecs.Entity, controls: ^input.Input, yaw, pitch: ^f32, dt: f32) {
	settings, configured := first_person_settings(world, entity)
	transform, has_transform := ecs.get_transform(world, entity)
	camera, has_camera := ecs.get_camera_3d(world, entity)
	if !configured || !has_transform || !has_camera { return }

	yaw^ += input.axis(controls, "look_x") * settings.mouse_sensitivity
	pitch^ += input.axis(controls, "look_y") * settings.mouse_sensitivity
	if pitch^ > 89 { pitch^ = 89 }
	if pitch^ < -89 { pitch^ = -89 }

	yaw_radians := yaw^ * f32(math.PI / 180)
	pitch_radians := pitch^ * f32(math.PI / 180)
	forward := [3]f32{
		f32(math.sin(f64(yaw_radians))) * f32(math.cos(f64(pitch_radians))),
		f32(math.sin(f64(pitch_radians))),
		f32(math.cos(f64(yaw_radians))) * f32(math.cos(f64(pitch_radians))),
	}

	move_x := input.axis(controls, "move_x")
	move_z := input.axis(controls, "move_z")
	horizontal := [2]f32{}
	if move_x != 0 || move_z != 0 {
		length := f32(math.sqrt(f64(move_x * move_x + move_z * move_z)))
		move_x /= length
		move_z /= length
		speed := settings.move_speed
		if input.is_down(controls, "sprint") { speed *= settings.sprint_multiplier }
		right := [3]f32{-forward[2], 0, forward[0]}
		horizontal = {
			(forward[0] * move_z + right[0] * move_x) * speed * dt,
			(forward[2] * move_z + right[2] * move_x) * speed * dt,
		}
	}
	ecs.move_character(world, entity, horizontal, input.pressed(controls, "jump"), dt)
	transform, _ = ecs.get_transform(world, entity)

	camera.target = {
		transform.position[0] + forward[0],
		transform.position[1] + forward[1],
		transform.position[2] + forward[2],
	}
	ecs.set_transform(world, entity, transform)
	ecs.set_camera_3d(world, entity, camera)
}
