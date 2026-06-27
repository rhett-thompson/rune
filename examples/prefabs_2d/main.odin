package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:render"

draw_prefabs :: proc(game: ^rune.Engine, world: ^ecs.World) {
	render.draw_scene_2d(world, rune.asset_manager(game))
}

main :: proc() {
	game, ok := rune.init("examples/prefabs_2d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/prefabs_2d/project.json")
		return
	}
	defer rune.shutdown(&game)

	world, scene_ok := rune.load_scene(&game, "examples/prefabs_2d/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the prefab scene")
		return
	}
	if !rune.register_system(&game, {name = "prefab_scene_draw", draw = draw_prefabs}) {
		fmt.eprintln("Could not register the prefab draw system")
		return
	}
	rune.run_scene(&game, &world)
}
