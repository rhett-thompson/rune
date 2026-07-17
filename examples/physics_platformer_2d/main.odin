package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

player: ecs.Entity
jump_height: f32 = 150
platform_ids := [3]string{"floor", "platform_left", "platform_right"}

Player_Controller :: struct {
	jump_height: f32,
}

update_physics :: proc(game: ^rune.Engine, world: ^ecs.World) {
	body, found := ecs.get_rigid_body_2d(world, player)
	if !found { return }
	body.velocity[0] = input.axis(rune.input_state(game), "move_x") * 220
	if input.pressed(rune.input_state(game), "jump") && body.grounded {
		body.velocity[1] = -jump_velocity(jump_height, ecs.Physics2D_Gravity * body.gravity_scale)
		body.grounded = false
	}
	ecs.set_rigid_body_2d(world, player, body)
}

jump_velocity :: proc(height, gravity: f32) -> f32 {
	if height <= 0 || gravity <= 0 { return 0 }
	return f32(math.sqrt(f64(2 * gravity * height)))
}

load_player_controller :: proc(world: ^ecs.World) -> bool {
	controller, found := ecs.get(world, player, Player_Controller)
	if !found { return true }
	if controller.jump_height <= 0 { return false }
	jump_height = controller.jump_height
	return true
}

draw_platformer :: proc(game: ^rune.Engine, world: ^ecs.World) {
	ball, ball_found := ecs.find_entity_by_id(world, "circle_ball")
	if ball_found {
		transform, has_transform := ecs.get_transform(world, ball)
		collider, has_collider := ecs.get_circle_collider_2d(world, ball)
		if has_transform && has_collider { rl.DrawCircle(i32(transform.position[0]), i32(transform.position[1]), collider.radius, rl.GOLD) }
	}
	pedestal, pedestal_found := ecs.find_entity_by_id(world, "circle_pedestal")
	if pedestal_found {
		transform, has_transform := ecs.get_transform(world, pedestal)
		collider, has_collider := ecs.get_circle_collider_2d(world, pedestal)
		if has_transform && has_collider { rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), collider.radius, rl.ORANGE) }
	}
	for id in platform_ids {
		entity, found := ecs.find_entity_by_id(world, id)
		if !found { continue }
		transform, transform_found := ecs.get_transform(world, entity)
		collider, collider_found := ecs.get_box_collider_2d(world, entity)
		if !transform_found || !collider_found { continue }
		width := i32(collider.size[0] * transform.scale[0])
		height := i32(collider.size[1] * transform.scale[1])
		rl.DrawRectangle(i32(transform.position[0]) - width / 2, i32(transform.position[1]) - height / 2, width, height, rl.DARKBLUE)
		rl.DrawRectangleLines(i32(transform.position[0]) - width / 2, i32(transform.position[1]) - height / 2, width, height, rl.SKYBLUE)
	}
}

reacquire_platformer_state :: proc(game: ^rune.Engine, world: ^ecs.World) {
	player, _ = ecs.find_entity_by_id(world, "player")
	jump_height = 150
	load_player_controller(world)
}

main :: proc() {
	game, ok := rune.init("examples/physics_platformer_2d/project.json")
	if !ok { fmt.eprintln("Could not load physics platformer project"); return }
	defer rune.shutdown(&game)
	if !ecs.register_component(
		rune.component_registry(&game),
		"PlayerController",
		Player_Controller,
		Player_Controller{jump_height = 150},
		"Platformer jump tuning",
	) {
		fmt.eprintln("Could not register PlayerController")
		return
	}

	if !rune.register_system(&game, {name = "platformer_physics", start = reacquire_platformer_state, fixed_update = update_physics, on_scene_reloaded = reacquire_platformer_state}) ||
	   !rune.register_system(&game, {name = "platformer_draw", draw = draw_platformer}) {
		fmt.eprintln("Could not register physics platformer systems")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
