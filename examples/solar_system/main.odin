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

world: ecs.World
bridge: r3d_bridge.Context

on_update :: proc(game: ^rune.Engine) {
	// The speeds come from the scene's typed Orbit and Rotator components.
	ecs.update_orbits(&world, game.delta_time)
	ecs.update_rotators(&world, game.delta_time)
}

on_draw :: proc(game: ^rune.Engine) {
	r3d_bridge.draw_scene_ex(&bridge, &world, rune.asset_manager(game), scene_view)
	rune.draw_gizmos(game, &world)
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

	bridge_ok: bool
	bridge, bridge_ok = r3d_bridge.init("examples/solar_system", rl.GetScreenWidth(), rl.GetScreenHeight())
	if !bridge_ok {
		fmt.eprintln("Could not initialize r3d")
		return
	}
	defer r3d_bridge.shutdown(&bridge)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/solar_system/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the solar-system scene")
		return
	}

	rune.run(&game, on_update, on_draw)
}
