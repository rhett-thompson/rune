package main

import "core:fmt"
import rune "rune:core"

main :: proc() {
	game, ok := rune.init("examples/registered_systems/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/registered_systems/project.json")
		return
	}
	defer rune.shutdown(&game)

	if !rune.register_system(&game, rune.System{name = "skeleton_movement", start = reacquire_demo_entities, update = skeleton_movement_system, on_scene_reloaded = reacquire_demo_entities}) ||
		!rune.register_system(&game, rune.System{name = "scene_draw", draw = scene_draw_system}) {
		fmt.eprintln("Could not initialize registered systems")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
