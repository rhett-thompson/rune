package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context
player, follow_camera, platform: ecs.Entity
avatar_body, avatar_head, avatar_front: ecs.Entity

scene_view := r3d_bridge.Scene3D_Settings {
	grid_slices = 24,
	grid_spacing = 1,
	draw_colliders = false,
	background_color = {38, 49, 67, 255},
}

initialize_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		bridge_ok: bool
		bridge, bridge_ok = r3d_bridge.init("examples/third_person_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !bridge_ok {fmt.eprintln("Could not initialize r3d")}
	}
	player, _ = ecs.find_entity_by_id(world, "player")
	follow_camera, _ = ecs.find_entity_by_id(world, "follow_camera")
	platform, _ = ecs.find_entity_by_id(world, "moving_platform")
	avatar_body, _ = ecs.find_entity_by_id(world, "player_body")
	avatar_head, _ = ecs.find_entity_by_id(world, "player_head")
	avatar_front, _ = ecs.find_entity_by_id(world, "player_front")
	camera_state = {}
	facing_yaw = 180
	footstep_distance = 0
	footsteps_moving = false
	reset_interactions()
	ecs.reset_triggers_3d(world)
	refresh_course_door_prompt(world)
	update_camera(game, world)
}

shutdown_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

fixed_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	submit_movement(game, world)
	update_course_door(world,game.fixed_delta_time)
	transform, found := ecs.get_transform(world, platform)
	body, has_body := ecs.get_rigid_body_3d(world, platform)
	if !found || !has_body {return}
	if transform.position[2] < -11 {body.velocity[2] = 1.5}
	if transform.position[2] > -5 {body.velocity[2] = -1.5}
	ecs.set_rigid_body_3d(world, platform, body)
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), scene_view) {
		example_text.draw("No active Camera3D entity", 24, 24, 28, rl.MAROON)
	}
	draw_course_zones(world)
}

on_draw_ui :: proc(game: ^rune.Engine, world: ^ecs.World) {
	example_text.draw("Rune Third Person Controller", 24, 24, 28, rl.RAYWHITE)
	example_text.draw("WASD move | Space jump | Shift sprint | Ctrl crouch | Wheel zoom", 24, 60, 18, rl.RAYWHITE)
	example_text.draw("Left-drag orbit | Right-drag orbit and face camera direction | F3 gizmos", 24, 86, 18, rl.LIGHTGRAY)
	motor, _ := ecs.get_character_controller_3d_state(world, player)
	example_text.draw(fmt.ctprintf("Grounded: %t   Crouched: %t   Stand blocked: %t   Camera blocked: %t",
		motor.grounded, motor.crouched, motor.stand_blocked, camera_state.obstructed), 24, 112, 18, rl.LIGHTGRAY)
	example_text.draw("Blue ramps | Orange stairs | Purple crawl tunnel | Green moving platform", 24, 138, 18, rl.RAYWHITE)
	example_text.draw(fmt.ctprintf("%d FPS",rl.GetFPS()),24,164,18,rl.GREEN)
	draw_interaction_ui(world)
	draw_inventory_ui(game,world)
	draw_zone_ui(world)
	draw_health_ui(world)
}

main :: proc() {
	game, ok := rune.init("examples/third_person_3d/project.json")
	if !ok {fmt.eprintln("Could not load examples/third_person_3d/project.json"); return}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) {fmt.eprintln("Could not load shared example font"); return}
	if !register_course_components(rune.component_registry(&game)) || !configure_course_saves(&game) {
		fmt.eprintln("Could not configure course components or saves: ",rune.last_save_error(&game))
		return
	}
	if !rune.register_system(&game, {
		name = "third_person_3d",
		start = initialize_scene,
		ui_update = sample_controls,
		fixed_update = fixed_update,
		post_physics = course_post_physics,
		update = update_gameplay,
		draw = on_draw,
		draw_ui = on_draw_ui,
		on_scene_reloaded = initialize_scene,
		on_save_restored = initialize_scene,
		shutdown = shutdown_scene,
	}) {
		fmt.eprintln("Could not register third-person system")
		return
	}
	if !rune.run(&game) {fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())}
}
