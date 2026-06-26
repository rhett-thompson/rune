package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:render"

world: ecs.World

on_update :: proc(game: ^rune.Engine) {
	rune.reload_scene_if_changed(game, &world, "examples/prefabs_2d/scenes/main.scene.json")
}

on_draw :: proc(game: ^rune.Engine) {
	render.draw_scene_2d(&world, rune.asset_manager(game))
	rune.draw_gizmos(game, &world)
}

main :: proc() {
	game, ok := rune.init("examples/prefabs_2d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/prefabs_2d/project.json")
		return
	}
	defer rune.shutdown(&game)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/prefabs_2d/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the prefab scene")
		return
	}
	rune.run(&game, on_update, on_draw)
}
