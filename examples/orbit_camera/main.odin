package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

world: ecs.World
bridge: r3d_bridge.Context

scene_view := r3d_bridge.Scene3D_Settings{
	grid_slices = 20,
	grid_spacing = 1,
}

orbit_camera: ecs.Entity

on_update :: proc(game: ^rune.Engine) {
	rune.update_orbit_cameras_3d(game, &world)
}

on_draw :: proc(game: ^rune.Engine) {
	if !r3d_bridge.draw_scene_ex(&bridge, &world, rune.asset_manager(game), scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rune.draw_gizmos(game, &world)

	rl.DrawText("Camera3D Orbit", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("The Camera3D entity's Transform orbits its JSON target.", 24, 60, 18, rl.GRAY)
	rl.DrawText("Hold left mouse and drag to orbit manually.", 24, 86, 18, rl.DARKGRAY)
	rl.DrawFPS(24, 112)
}

main :: proc() {
	game, ok := rune.init("examples/orbit_camera/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/orbit_camera/project.json")
		return
	}
	defer rune.shutdown(&game)

	bridge_ok: bool
	bridge, bridge_ok = r3d_bridge.init("examples/orbit_camera", rl.GetScreenWidth(), rl.GetScreenHeight())
	if !bridge_ok {
		fmt.eprintln("Could not initialize r3d")
		return
	}
	defer r3d_bridge.shutdown(&bridge)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/orbit_camera/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the orbit-camera scene")
		return
	}
	found: bool
	orbit_camera, found = ecs.find_entity_by_id(&world, "orbit_camera")
	if !found {
		fmt.eprintln("Scene is missing entity ID: orbit_camera")
		return
	}

	rune.run(&game, on_update, on_draw)
}
