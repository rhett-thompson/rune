package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context

scene_view := r3d_bridge.Scene3D_Settings{grid_slices = 20, grid_spacing = 1}

wide_camera:  ecs.Entity
front_camera: ecs.Entity
side_camera:  ecs.Entity

initialize_cameras :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		bridge_ok: bool
		bridge, bridge_ok = r3d_bridge.init("examples/camera_switching", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !bridge_ok { fmt.eprintln("Could not initialize r3d") }
	}
	wide_camera, _ = ecs.find_entity_by_id(world, "wide_camera")
	front_camera, _ = ecs.find_entity_by_id(world, "front_camera")
	side_camera, _ = ecs.find_entity_by_id(world, "side_camera")
}

shutdown_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	game_input := rune.input_state(game)
	if input.is_down(game_input, "camera_one") { ecs.set_active_camera_3d(world, wide_camera) }
	if input.is_down(game_input, "camera_two") { ecs.set_active_camera_3d(world, front_camera) }
	if input.is_down(game_input, "camera_three") { ecs.set_active_camera_3d(world, side_camera) }
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rl.DrawText("Multiple Camera Switching", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("[1] Wide  [2] Front  [3] Side", 24, 60, 20, rl.GRAY)
	rl.DrawText("The selected Camera3D component is active.", 24, 88, 18, rl.DARKGRAY)
	rl.DrawFPS(24, 118)
}

main :: proc() {
	game, ok := rune.init("examples/camera_switching/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/camera_switching/project.json")
		return
	}
	defer rune.shutdown(&game)

	if !rune.register_system(&game, {
		name = "camera_switching",
		start = initialize_cameras,
		update = on_update,
		draw = on_draw,
		on_scene_reloaded = initialize_cameras,
		shutdown = shutdown_scene,
	}) {
		fmt.eprintln("Could not register camera-switching system")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
