package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:jsonutil"
import "rune:render"
import rl "vendor:raylib"

world: ecs.World
player: ecs.Entity
jump_height: f32 = 150
platform_ids := [3]string{"floor", "platform_left", "platform_right"}

on_update :: proc(game: ^rune.Engine) {
	body, found := ecs.get_rigid_body_2d(&world, player)
	if !found { return }
	body.velocity[0] = input.axis(rune.input_state(game), "move_x") * 220
	if input.pressed(rune.input_state(game), "jump") && body.grounded {
		body.velocity[1] = -jump_velocity(jump_height, ecs.Physics2D_Gravity * body.gravity_scale)
		body.grounded = false
	}
	ecs.set_rigid_body_2d(&world, player, body)
	ecs.physics_2d_update(&world, game.delta_time)
}

jump_velocity :: proc(height, gravity: f32) -> f32 {
	if height <= 0 || gravity <= 0 { return 0 }
	return f32(math.sqrt(f64(2 * gravity * height)))
}

load_player_controller :: proc() -> bool {
	data, found := ecs.get_component(&world, player, "PlayerController")
	if !found { return true }
	object, ok := data.(json.Object)
	if !ok { return false }
	if value, has_height := object["jump_height"]; has_height {
		height, height_ok := jsonutil.number(value)
		if !height_ok || height <= 0 { return false }
		jump_height = height
	}
	return true
}

on_draw :: proc(game: ^rune.Engine) {
	ball, ball_found := ecs.find_entity_by_id(&world, "circle_ball")
	if ball_found {
		transform, has_transform := ecs.get_transform(&world, ball)
		collider, has_collider := ecs.get_circle_collider_2d(&world, ball)
		if has_transform && has_collider { rl.DrawCircle(i32(transform.position[0]), i32(transform.position[1]), collider.radius, rl.GOLD) }
	}
	pedestal, pedestal_found := ecs.find_entity_by_id(&world, "circle_pedestal")
	if pedestal_found {
		transform, has_transform := ecs.get_transform(&world, pedestal)
		collider, has_collider := ecs.get_circle_collider_2d(&world, pedestal)
		if has_transform && has_collider { rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), collider.radius, rl.ORANGE) }
	}
	for id in platform_ids {
		entity, found := ecs.find_entity_by_id(&world, id)
		if !found { continue }
		transform, transform_found := ecs.get_transform(&world, entity)
		collider, collider_found := ecs.get_box_collider_2d(&world, entity)
		if !transform_found || !collider_found { continue }
		width := i32(collider.size[0] * transform.scale[0])
		height := i32(collider.size[1] * transform.scale[1])
		rl.DrawRectangle(i32(transform.position[0]) - width / 2, i32(transform.position[1]) - height / 2, width, height, rl.DARKBLUE)
		rl.DrawRectangleLines(i32(transform.position[0]) - width / 2, i32(transform.position[1]) - height / 2, width, height, rl.SKYBLUE)
	}
	render.draw_scene_2d(&world, rune.asset_manager(game))
	rune.draw_gizmos(game, &world)
}

main :: proc() {
	game, ok := rune.init("examples/physics_platformer_2d/project.json")
	if !ok { fmt.eprintln("Could not load physics platformer project"); return }
	defer rune.shutdown(&game)

	world, ok = rune.load_scene(&game, "examples/physics_platformer_2d/scenes/main.scene.json")
	if !ok { fmt.eprintln("Could not load physics platformer scene"); return }
	defer ecs.physics_2d_shutdown(&world)

	player, ok = ecs.find_entity_by_id(&world, "player")
	if !ok { fmt.eprintln("Physics platformer scene is missing player"); return }
	if !load_player_controller() { fmt.eprintln("PlayerController must be an object with positive jump_height"); return }
	rune.run(&game, on_update, on_draw)
}
