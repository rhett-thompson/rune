package main

import rune "rune:core"

main :: proc() {
	game, ok := rune.init("examples/shapes_2d/project.json")
	if !ok {return}
	defer rune.shutdown(&game)
	rune.run_project(&game)
}
