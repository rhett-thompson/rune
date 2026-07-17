package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context

scene_view := r3d_bridge.Scene3D_Settings{
	grid_slices = 20,
	grid_spacing = 1,
}

initialize_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if bridge.initialized { return }
	bridge_ok: bool
	bridge, bridge_ok = r3d_bridge.init("examples/orbit_camera", rl.GetScreenWidth(), rl.GetScreenHeight())
	if !bridge_ok { fmt.eprintln("Could not initialize r3d") }
}

shutdown_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
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

	if !rune.register_system(&game, {name = "orbit_camera_draw", start = initialize_scene, draw = on_draw, shutdown = shutdown_scene}) {
		fmt.eprintln("Could not register orbit-camera draw system")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
