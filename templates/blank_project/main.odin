package main

import "core:fmt"
import rune "rune:core"

main :: proc() {
	engine, ok := rune.init("project.json")
	if !ok {
		fmt.eprintln("Could not load project.json; run from the game project directory.")
		return
	}
	defer rune.shutdown(&engine)

	if !rune.run(&engine) {fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())}
}
