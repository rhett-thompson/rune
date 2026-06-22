package main

import "core:fmt"
import "core:strings"
import engine "engine:core"
import "engine:ecs"
import "engine:scene"
import rl "vendor:raylib"

loaded_scene: scene.Scene
world: ecs.World
scene_title: cstring

on_update :: proc(game: ^engine.Engine) {}

on_draw :: proc(game: ^engine.Engine) {
	rl.DrawText("Hello from Rune!", 64, 64, 32, rl.DARKGRAY)
	rl.DrawText(scene_title, 64, 112, 20, rl.GRAY)
	rl.DrawText("One entity loaded from JSON", 64, 142, 20, rl.GRAY)
	rl.DrawCircle(100, 215, 32, rl.SKYBLUE)
	rl.DrawText("Close the window when you are done exploring.", 64, 280, 18, rl.DARKGRAY)
}

main :: proc() {
	game, ok := engine.init("examples/hello_world/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/hello_world/project.json")
		return
	}

	scene_ok: bool
	loaded_scene, scene_ok = scene.load("examples/hello_world/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load the hello-world scene")
		engine.shutdown(&game)
		return
	}
	scene_title, _ = strings.clone_to_cstring(loaded_scene.name)

	world = ecs.init()
	if !scene.instantiate(&world, engine.component_registry(&game), loaded_scene) {
		fmt.eprintln("Could not instantiate the hello-world scene components")
		engine.shutdown(&game)
		return
	}

	engine.run(&game, on_update, on_draw)
}
