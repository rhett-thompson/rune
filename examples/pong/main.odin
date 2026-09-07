package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"

world: ^ecs.World
game_state: Pong_Game

register_pong_components :: proc(game: ^rune.Engine) -> bool {
	registry := rune.component_registry(game)
	return(
		ecs.register_component(
			registry,
			"PongArena",
			Pong_Arena,
			Pong_Arena{},
			"Pong court dimensions and presentation",
		) &&
		ecs.register_component(
			registry,
			"PongPaddle",
			Pong_Paddle,
			Pong_Paddle{},
			"Player or computer controlled Pong paddle",
		) &&
		ecs.register_component(registry, "PongBall", Pong_Ball, Pong_Ball{}, "Moving Pong ball and serve settings") &&
		ecs.register_component(
			registry,
			"PongMatch",
			Pong_Match,
			Pong_Match{},
			"Pong scoring, mode, and match state",
		) \
	)
}

on_update :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	update_pong(&game_state, engine)
}

on_draw :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	draw_pong(&game_state)
}

on_reload :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	world = scene_world
	if load_pong_game(&game_state, scene_world) {
		reset_match(&game_state)
	}
}

on_start :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) { on_reload(engine, scene_world) }

main :: proc() {

	engine, ok := rune.init("examples/pong/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/pong/project.json")
		return
	}

	defer rune.shutdown(&engine)

	if !register_pong_components(&engine) {
		fmt.eprintln("Could not register Pong components")
		return
	}

	if !rune.register_system(
		&engine,
		{name = "pong", start = on_start, update = on_update, draw = on_draw, on_scene_reloaded = on_reload},
	) { fmt.eprintln("Could not register Pong system"); return }

	if !rune.run(&engine) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
