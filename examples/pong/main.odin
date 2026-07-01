package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"

world: ecs.World
game_state: Pong_Game

register_pong_components :: proc(game: ^rune.Engine) -> bool {
	registry := rune.component_registry(game)
	return ecs.register_component(registry, {name = "PongArena", description = "Pong court dimensions and presentation"}) &&
	       ecs.register_component(registry, {name = "PongPaddle", description = "Player or computer controlled Pong paddle"}) &&
	       ecs.register_component(registry, {name = "PongBall", description = "Moving Pong ball and serve settings"}) &&
	       ecs.register_component(registry, {name = "PongMatch", description = "Pong scoring, mode, and match state"})
}

on_update :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	update_pong(&game_state, engine)
}
on_draw :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) { draw_pong(&game_state) }
on_reload :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	if load_pong_game(&game_state, scene_world) { reset_match(&game_state) }
}

main :: proc() {
	engine, ok := rune.init("examples/pong/project.json")
	if !ok { fmt.eprintln("Could not load examples/pong/project.json"); return }
	defer rune.shutdown(&engine)
	if !register_pong_components(&engine) { fmt.eprintln("Could not register Pong components"); return }

	scene_ok: bool
	world, scene_ok = rune.load_scene(&engine, "examples/pong/scenes/main.scene.json")
	if !scene_ok { fmt.eprintln("Could not load the Pong scene"); return }
	if !load_pong_game(&game_state, &world) {
		fmt.eprintln("Pong scene requires an arena, ball, match, four audio players, and two paddles")
		return
	}
	if !rune.register_system(&engine, {
		name = "pong",
		update = on_update,
		draw = on_draw,
		on_scene_reloaded = on_reload,
	}) { fmt.eprintln("Could not register Pong system"); return }
	reset_match(&game_state)
	rune.run_scene(&engine, &world)
}
