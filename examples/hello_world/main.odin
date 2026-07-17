package main

import "core:fmt"
import "core:strings"
import rune "rune:core"
import "rune:ecs"
import rl "vendor:raylib"

mecha_font: rl.Font

Greeting :: struct {
	text: string,
}

draw_hello_world :: proc(game: ^rune.Engine, world: ^ecs.World) {
	text := "Hello from Rune!"
	for entity in ecs.query(world, Greeting) {
		if greeting, found := ecs.get(world, entity, Greeting); found { text = greeting.text }
		break
	}
	c_text, _ := strings.clone_to_cstring(text, context.temp_allocator)
	rl.DrawTextEx(mecha_font, c_text, {64, 64}, 32, 1, rl.DARKGRAY)
	rl.DrawTextEx(mecha_font, "One scene loaded from JSON", {64, 112}, 20, 1, rl.GRAY)
	rl.DrawTextEx(mecha_font, "One entity loaded from JSON", {64, 142}, 20, 1, rl.GRAY)
	rl.DrawCircle(100, 215, 32, rl.SKYBLUE)
	rl.DrawTextEx(mecha_font, "Close the window when you are done exploring.", {64, 280}, 18, 1, rl.DARKGRAY)
}

main :: proc() {
	game, ok := rune.init("examples/hello_world/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/hello_world/project.json")
		return
	}
	defer rune.shutdown(&game)
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

	mecha_font = rl.LoadFont("examples/hello_world/assets/fonts/mecha.png")
	defer rl.UnloadFont(mecha_font)

	if !rune.register_system(&game, {name = "hello_world_draw", draw = draw_hello_world}) {
		fmt.eprintln("Could not register the hello_world draw system")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run the startup scene: ", rune.last_scene_error()) }
}
