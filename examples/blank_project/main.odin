package main

import "core:fmt"
import rune "rune:core"

main :: proc() {
	engine, ok := rune.init("examples/blank_project/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/blank_project/project.json")
		return
	}
	defer rune.shutdown(&engine)

	world, scene_ok := rune.load_scene(
		&engine,
		"examples/blank_project/scenes/main.scene.json",
	)
	if !scene_ok {
		fmt.eprintln("Could not load examples/blank_project/scenes/main.scene.json")
		return
	}

	rune.run_scene(&engine, &world)
}
