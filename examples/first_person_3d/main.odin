package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context
player, camera_entity, platform: ecs.Entity
camera_yaw: f32 = 180
camera_pitch: f32
cursor_captured := true

scene_view := r3d_bridge.Scene3D_Settings {
	grid_slices    = 24,
	grid_spacing   = 1,
	draw_colliders = false,
	background_color = {38, 49, 67, 255},
}

initialize_player :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		bridge_ok: bool
		bridge, bridge_ok = r3d_bridge.init("examples/first_person_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !bridge_ok { fmt.eprintln("Could not initialize r3d") }
	}
	player, _ = ecs.find_entity_by_id(world, "player")
	camera_entity, _ = ecs.find_entity_by_id(world, "camera")
	platform, _ = ecs.find_entity_by_id(world, "moving_platform")
	head_bob = {}
	camera_height = {}
	weapon_jump = {}
	footstep_distance = 0
	footsteps_moving = false
	update_camera(game,world)
}

shutdown_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	shutdown_weapon()
	r3d_bridge.shutdown(&bridge)
}

toggle_cursor :: proc() {
	cursor_captured=!cursor_captured
	if cursor_captured {rl.DisableCursor()} else {rl.EnableCursor()}
}

move_platform :: proc(game:^rune.Engine,world:^ecs.World) {
	submit_movement(game,world)
	transform,found:=ecs.get_transform(world,platform)
	body,has_body:=ecs.get_rigid_body_3d(world,platform)
	if !found || !has_body {return}
	if transform.position[2]< -11 {body.velocity[2]=1.5}
	if transform.position[2]> -5 {body.velocity[2]= -1.5}
	ecs.set_rigid_body_3d(world,platform,body)
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
}

on_draw_ui :: proc(game: ^rune.Engine, world: ^ecs.World) {
	draw_weapon(game, world)
	rl.DrawText("Rune First Person Controller", 24, 24, 28, rl.RAYWHITE)
	rl.DrawText("WASD move | Space jump | Shift sprint | Ctrl crouch | Escape cursor", 24, 60, 18, rl.RAYWHITE)
	motor,_:=ecs.get_character_controller_3d_state(world,player)
	rl.DrawText(fmt.ctprintf("Grounded: %t   Crouched: %t   Stand blocked: %t",motor.grounded,motor.crouched,motor.stand_blocked),24,86,18,rl.LIGHTGRAY)
	rl.DrawText("Blue ramps | Orange stairs | Purple crawl tunnel | Green moving platform",24,138,18,rl.RAYWHITE)
	rl.DrawFPS(24, 112)
}

main :: proc() {
	game, ok := rune.init("examples/first_person_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/first_person_3d/project.json")
		return
	}
	defer rune.shutdown(&game)
	if !ecs.register_component(
		rune.component_registry(&game),
		"FirstPersonController",
		First_Person_Settings,
		First_Person_Defaults,
		"First-person camera look, eye height, and head bob tuning",
	) {
		fmt.eprintln("Could not register FirstPersonController")
		return
	}

	if !ecs.register_component(
		rune.component_registry(&game), "WeaponViewmodel", Weapon_Viewmodel,
		Weapon_Viewmodel_Defaults, "First-person weapon overlay placement and lens",
	) {
		fmt.eprintln("Could not register WeaponViewmodel")
		return
	}

	if !rune.register_system(
		&game,
		{
			name = "first_person_3d",
			start = initialize_player,
			ui_update = sample_controls,
			fixed_update = move_platform,
			post_physics = on_post_physics,
			update = update_camera,
			draw = on_draw,
			draw_ui = on_draw_ui,
			on_scene_reloaded = initialize_player,
			shutdown = shutdown_scene,
		},
	) {
		fmt.eprintln("Could not register first-person system")
		return
	}

	rl.DisableCursor()
	if !rune.run(&game) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
