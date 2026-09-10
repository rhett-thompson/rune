package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import rl "vendor:raylib"

Greeting :: struct {
	text: string,
}

draw_hello_world :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for entity in ecs.query2(world, ecs.Transform, Greeting) {
		transform, _ := ecs.get(world, entity, ecs.Transform)
		greeting, _ := ecs.get(world, entity, Greeting)
		example_text.draw(
			fmt.ctprintf("%s", greeting.text),
			i32(transform.position[0]),
			i32(transform.position[1]),
			32,
			rl.DARKGRAY,
		)
	}
}

main :: proc() {
	game, ok := rune.init("examples/hello_world/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/hello_world/project.json")
		return
	}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }
	if !ecs.register_component(
		rune.component_registry(&game),
		"Greeting",
		Greeting,
		Greeting{text = "Hello from Rune!"},
		"Text displayed by the hello-world example",
	) {
		fmt.eprintln("Could not register Greeting")
		return
	}

	if !rune.register_system(&game, {name = "hello_world_draw", draw = draw_hello_world}) {
		fmt.eprintln("Could not register the hello_world draw system")
		return
	}
	if !rune.run(&game) {
		fmt.eprintln("Could not run the startup scene: ", rune.last_scene_error())
	}
}
