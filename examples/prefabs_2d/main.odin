package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"

main :: proc() {
	game, ok := rune.init("examples/prefabs_2d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/prefabs_2d/project.json")
		return
	}
	defer rune.shutdown(&game)
	if !ecs.register_data_component(
		rune.component_registry(&game),
		"PrefabMarker",
		"Marks a prefab-authored attachment point",
	) {
		fmt.eprintln("Could not register PrefabMarker")
		return
	}

	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
