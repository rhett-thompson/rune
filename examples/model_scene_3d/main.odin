package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

scene_view := r3d_bridge.Scene3D_Settings {
	grid_slices  = 20,
	grid_spacing = 1,
}
bridge: r3d_bridge.Context
pyramid: ecs.Entity

initialize_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		bridge_ok: bool
		bridge, bridge_ok = r3d_bridge.init("examples/model_scene_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !bridge_ok { fmt.eprintln("Could not initialize r3d") }
	}
	pyramid, _ = ecs.find_entity_by_id(world, "pyramid")
}

shutdown_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	transform, found := ecs.get_transform(world, pyramid)
	if !found { return }
	transform.rotation[1] += 45 * game.delta_time
	ecs.set_transform(world, pyramid, transform)
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), scene_view) {
		example_text.draw("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	example_text.draw("Rune Model Scene 3D", 24, 24, 28, rl.DARKGRAY)
	example_text.draw("Left mouse: orbit camera   Mouse wheel: zoom", 24, 60, 18, rl.GRAY)
	rl.DrawFPS(24, 94)
}

main :: proc() {
	game, ok := rune.init("examples/model_scene_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/model_scene_3d/project.json")
		return
	}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }

	if !rune.register_system(
		&game,
		{
			name = "model_scene_3d",
			start = initialize_scene,
			update = on_update,
			draw = on_draw,
			on_scene_reloaded = initialize_scene,
			shutdown = shutdown_scene,
		},
	) {
		fmt.eprintln("Could not register model-scene system")
		return
	}
	if !rune.run(&game) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
