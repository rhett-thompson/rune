package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

world: ecs.World
bridge: r3d_bridge.Context

scene_view := r3d_bridge.Scene3D_Settings{grid_slices = 20, grid_spacing = 1}

wide_camera:  ecs.Entity
front_camera: ecs.Entity
side_camera:  ecs.Entity

on_update :: proc(game: ^rune.Engine) {
	game_input := rune.input_state(game)
	if input.is_down(game_input, "camera_one") { ecs.set_active_camera_3d(&world, wide_camera) }
	if input.is_down(game_input, "camera_two") { ecs.set_active_camera_3d(&world, front_camera) }
	if input.is_down(game_input, "camera_three") { ecs.set_active_camera_3d(&world, side_camera) }
}

on_draw :: proc(game: ^rune.Engine) {
	if !r3d_bridge.draw_scene_ex(&bridge, &world, rune.asset_manager(game), scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rune.draw_gizmos(game, &world)
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

	bridge_ok: bool
	bridge, bridge_ok = r3d_bridge.init("examples/camera_switching", rl.GetScreenWidth(), rl.GetScreenHeight())
	if !bridge_ok {
		fmt.eprintln("Could not initialize r3d")
		return
	}
	defer r3d_bridge.shutdown(&bridge)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/camera_switching/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the camera-switching scene")
		return
	}
	wide_found, front_found, side_found: bool
	wide_camera, wide_found = ecs.find_entity_by_id(&world, "wide_camera")
	front_camera, front_found = ecs.find_entity_by_id(&world, "front_camera")
	side_camera, side_found = ecs.find_entity_by_id(&world, "side_camera")
	if !wide_found || !front_found || !side_found {
		fmt.eprintln("Scene is missing a required camera entity ID")
		return
	}
	rune.run(&game, on_update, on_draw)
}
