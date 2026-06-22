package main

import "core:fmt"
import engine "engine:core"
import "engine:ecs"
import "engine:render"
import "engine:scene"
import rl "vendor:raylib"

scene_view := render.Scene3D_Settings{
	camera = {position = {11.0, 9.0, 11.0}, target = {0.0, 0.0, 0.0}, up = {0.0, 1.0, 0.0}, fovy = 45.0},
	grid_slices = 24,
	grid_spacing = 1.0,
}

world: ecs.World

on_update :: proc(game: ^engine.Engine) {
	// Behaviour still lives in Odin; rendering and matrix scoping stay in the engine.
	sun, has_sun := ecs.get_transform(&world, ecs.Entity(1))
	if has_sun { sun.rotation[1] += 12.0 * game.delta_time; ecs.set_transform(&world, ecs.Entity(1), sun) }
	earth, has_earth := ecs.get_transform(&world, ecs.Entity(2))
	if has_earth { earth.rotation[1] += 160.0 * game.delta_time; ecs.set_transform(&world, ecs.Entity(2), earth) }
}

on_draw :: proc(game: ^engine.Engine) {
	render.draw_scene_3d(&world, scene_view)
	rl.DrawText("Rune Solar System", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("Sun > Earth > Moon: child transforms inherit parent rotation", 24, 60, 18, rl.GRAY)
	rl.DrawFPS(24, 94)
}

main :: proc() {
	game, ok := engine.init("examples/solar_system/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/solar_system/project.json")
		return
	}

	loaded_scene, scene_ok := scene.load("examples/solar_system/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load the solar-system scene")
		engine.shutdown(&game)
		return
	}

	world = ecs.init()
	if !scene.instantiate(&world, engine.component_registry(&game), loaded_scene) {
		fmt.eprintln("Could not instantiate the solar-system scene components")
		engine.shutdown(&game)
		return
	}

	engine.run(&game, on_update, on_draw)
}
