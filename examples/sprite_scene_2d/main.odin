package main

import "core:fmt"
import rune "rune:core"

main :: proc() {
	game, ok := rune.init("examples/sprite_scene_2d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/sprite_scene_2d/project.json")
		return
	}
	defer rune.shutdown(&game)

	if !rune.run(&game) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
