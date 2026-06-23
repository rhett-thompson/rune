package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"

main :: proc() {
	game, ok := rune.init("examples/registered_systems/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/registered_systems/project.json")
		return
	}
	world, scene_ok := rune.load_scene(&game, "examples/registered_systems/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the registered-systems scene")
		rune.shutdown(&game)
		return
	}
	reacquire_demo_entities(&game, &world)
	if demo_skeleton == ecs.Entity(0) ||
		!rune.register_system(&game, rune.System{name = "skeleton_movement", update = skeleton_movement_system, on_scene_reloaded = reacquire_demo_entities}) ||
		!rune.register_system(&game, rune.System{name = "scene_draw", draw = scene_draw_system}) {
		fmt.eprintln("Could not initialize registered systems")
		rune.shutdown(&game)
		return
	}
	rune.run_scene(&game, &world)
}
