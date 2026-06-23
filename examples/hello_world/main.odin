package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import rl "vendor:raylib"

world: ecs.World
mecha_font: rl.Font

on_update :: proc(game: ^rune.Engine) {}

on_draw :: proc(game: ^rune.Engine) {
	rl.DrawTextEx(mecha_font, "Hello from Rune!", {64, 64}, 32, 1, rl.DARKGRAY)
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
	mecha_font = rl.LoadFont("examples/hello_world/assets/fonts/mecha.png")

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/hello_world/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the hello-world scene")
		rune.shutdown(&game)
		return
	}

	rune.run(&game, on_update, on_draw)
}
