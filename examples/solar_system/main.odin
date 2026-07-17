package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

scene_view := r3d_bridge.Scene3D_Settings{
	grid_slices = 24,
	grid_spacing = 1.0,
}

bridge: r3d_bridge.Context

initialize_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if bridge.initialized { return }
	bridge_ok: bool
	bridge, bridge_ok = r3d_bridge.init("examples/solar_system", rl.GetScreenWidth(), rl.GetScreenHeight())
	if !bridge_ok { fmt.eprintln("Could not initialize r3d") }
}

shutdown_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	// The speeds come from the scene's typed Orbit and Rotator components.
	ecs.update_orbits(world, game.delta_time)
	ecs.update_rotators(world, game.delta_time)
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), scene_view)
	rl.DrawText("Rune Solar System", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("Earth orbits at 12°/s, spins at 48°/s; Moon orbits at 160°/s", 24, 60, 18, rl.GRAY)
	rl.DrawFPS(24, 94)
}

main :: proc() {
	game, ok := rune.init("examples/solar_system/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/solar_system/project.json")
		return
	}
	defer rune.shutdown(&game)

	if !rune.register_system(&game, {name = "solar_system", start = initialize_scene, update = on_update, draw = on_draw, shutdown = shutdown_scene}) {
		fmt.eprintln("Could not register solar-system system")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
