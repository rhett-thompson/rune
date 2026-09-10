package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for entity in ecs.query2(world, ecs.Transform, Mover) {
		mover_system(world, entity, input.axis(rune.input_state(game), "move_x"), game.delta_time)
	}
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	example_text.draw("Custom Mover", 32, 32, 28, rl.DARKGRAY)
	example_text.draw("A / D or Left / Right to move", 32, 72, 18, rl.GRAY)
	for entity in ecs.query2(world, ecs.Transform, Mover) {
		transform, _ := ecs.get(world, entity, ecs.Transform)
		rl.DrawCircle(i32(transform.position[0]), i32(transform.position[1]), 28, rl.MAROON)
	}
}

main :: proc() {
	game, ok := rune.init("examples/custom_mover/project.json")
	if !ok {
		fmt.eprintln("Could not load the custom-mover project")
		return
	}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }
	if !ecs.register_component(
		rune.component_registry(&game),
		"Mover",
		Mover,
		Mover{speed = 120},
		"Horizontal movement speed",
	) {
		fmt.eprintln("Could not register the typed Mover component")
		return
	}

	if !rune.register_system(&game, {name = "mover", update = on_update, draw = on_draw}) {
		fmt.eprintln("Could not register mover system")
		return
	}
	if !rune.run(&game) {
		fmt.eprintln("Could not run the startup scene: ", rune.last_scene_error())
	}
}
