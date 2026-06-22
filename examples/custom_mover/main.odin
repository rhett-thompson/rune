package main

import "core:fmt"
import engine "engine:core"
import "engine:ecs"
import "engine:scene"
import rl "vendor:raylib"

world: ecs.World
moving_ball: ecs.Entity

on_update :: proc(game: ^engine.Engine) {
	mover_system(&world, moving_ball, game.delta_time)

}

on_draw :: proc(game: ^engine.Engine) {
	transform, found := ecs.get_transform(&world, moving_ball)
	if !found {
		return
	}

	rl.DrawText("Custom Mover updates a typed Transform", 32, 32, 28, rl.DARKGRAY)
	rl.DrawText("The Mover speed comes from scene JSON; behaviour stays in Odin.", 32, 72, 18, rl.GRAY)
	rl.DrawCircle(i32(transform.position[0]), i32(transform.position[1]), 28, rl.MAROON)
	rl.DrawFPS(32, 112)
}

main :: proc() {
	game, ok := engine.init("examples/custom_mover/project.json")
	if !ok {
		fmt.eprintln("Could not load the custom-mover project")
		return
	}

	loaded_scene, scene_ok := scene.load("examples/custom_mover/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load the custom-mover scene")
		engine.shutdown(&game)
		return
	}

	world = ecs.init()
	if !scene.instantiate(&world, engine.component_registry(&game), loaded_scene) {
		fmt.eprintln("Could not instantiate custom-mover components")
		engine.shutdown(&game)
		return
	}

	// The scene has one entity, so its runtime ID is the first entity ID.
	moving_ball = ecs.Entity(1)
	engine.run(&game, on_update, on_draw)
}
