package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

scene_view := r3d_bridge.Scene3D_Settings {
	grid_slices  = 20,
	grid_spacing = 1.0,
}

bridge: r3d_bridge.Context
cube: ecs.Entity

initialize_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		bridge_ok: bool
		bridge, bridge_ok = r3d_bridge.init("examples/hello_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !bridge_ok { fmt.eprintln("Could not initialize r3d") }
	}
	cube, _ = ecs.find_entity_by_id(world, "cube")
}

shutdown_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	transform, found := ecs.get_transform(world, cube)
	if found {
		transform.rotation[0] += 19.25 * game.delta_time
		transform.rotation[1] += 55.0 * game.delta_time
		ecs.set_transform(world, cube, transform)
	}
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), scene_view) {
		example_text.draw("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
}

main :: proc() {

	game, ok := rune.init("examples/hello_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/hello_3d/project.json")
		return
	}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }

	if !rune.register_system(
		&game,
		{
			name = "hello_3d",
			start = initialize_scene,
			update = on_update,
			draw = on_draw,
			on_scene_reloaded = initialize_scene,
			shutdown = shutdown_scene,
		},
	) {
		fmt.eprintln("Could not register hello-3D system")
		return
	}
	if !rune.run(&game) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
