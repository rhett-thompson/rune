package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

world: ecs.World
moving_ball: ecs.Entity

on_update :: proc(game: ^rune.Engine) {
	mover_system(&world, moving_ball, input.axis(rune.input_state(game), "move_x"), game.delta_time)
}

on_draw :: proc(game: ^rune.Engine) {
	transform, found := ecs.get_transform(&world, moving_ball)
	if !found {
		return
	}

	rl.DrawText("Custom Mover updates a typed Transform", 32, 32, 28, rl.DARKGRAY)
	rl.DrawText("Use A/D or Left/Right. Input comes from input/default.input.json.", 32, 72, 18, rl.GRAY)
	rl.DrawCircle(i32(transform.position[0]), i32(transform.position[1]), 28, rl.MAROON)
	rl.DrawFPS(32, 112)
}

main :: proc() {
	game, ok := rune.init("examples/custom_mover/project.json")
	if !ok {
		fmt.eprintln("Could not load the custom-mover project")
		return
	}

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/custom_mover/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the custom-mover scene")
		rune.shutdown(&game)
		return
	}

	found: bool
	moving_ball, found = ecs.find_entity_by_id(&world, "moving_ball")
	if !found {
		fmt.eprintln("Scene is missing entity ID: moving_ball")
		rune.shutdown(&game)
		return
	}
	rune.run(&game, on_update, on_draw)
}
