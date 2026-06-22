package main

import "core:fmt"
import engine "engine:core"
import "engine:ecs"
import "engine:render"
import "engine:scene"
import rl "vendor:raylib"

scene_view := render.Scene3D_Settings{
	camera = {position = {4.5, 3.0, 4.5}, target = {0.0, 0.5, 0.0}, up = {0.0, 1.0, 0.0}, fovy = 45.0},
	grid_slices = 20,
	grid_spacing = 1.0,
}

world: ecs.World

on_update :: proc(game: ^engine.Engine) {
	transform, found := ecs.get_transform(&world, ecs.Entity(1))
	if found {
		transform.rotation[0] += 19.25 * game.delta_time
		transform.rotation[1] += 55.0 * game.delta_time
		ecs.set_transform(&world, ecs.Entity(1), transform)
	}
}

on_draw :: proc(game: ^engine.Engine) {
	render.draw_scene_3d(&world, scene_view)
	rl.DrawText("Rune 3D Hello World", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("A JSON scene with a rotating cube", 24, 60, 18, rl.GRAY)
	rl.DrawFPS(24, 94)
}

main :: proc() {
	game, ok := engine.init("examples/hello_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/hello_3d/project.json")
		return
	}

	loaded_scene, scene_ok := scene.load("examples/hello_3d/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load the 3D hello-world scene")
		engine.shutdown(&game)
		return
	}

	world = ecs.init()
	if !scene.instantiate(&world, engine.component_registry(&game), loaded_scene) {
		fmt.eprintln("Could not instantiate the 3D scene components")
		engine.shutdown(&game)
		return
	}

	engine.run(&game, on_update, on_draw)
}
