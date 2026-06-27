package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"

world: ecs.World
game_state: Tanks_Game

register_tanks_components :: proc(game: ^rune.Engine) -> bool {
	registry := rune.component_registry(game)
	return ecs.register_component(registry, {name = "TanksArena", description = "Tank arena dimensions, walls, and presentation"}) &&
	       ecs.register_component(registry, {name = "Tank", description = "Player or computer controlled tank"}) &&
	       ecs.register_component(registry, {name = "TanksMatch", description = "Tank match scoring and round state"})
}

on_update :: proc(engine: ^rune.Engine) { update_tanks(&game_state, engine) }
on_draw :: proc(engine: ^rune.Engine) { draw_tanks(&game_state) }

main :: proc() {
	engine, ok := rune.init("examples/tanks/project.json")
	if !ok { fmt.eprintln("Could not load examples/tanks/project.json"); return }
	defer rune.shutdown(&engine)
	if !register_tanks_components(&engine) { fmt.eprintln("Could not register Tanks components"); return }

	scene_ok: bool
	world, scene_ok = rune.load_scene(&engine, "examples/tanks/scenes/main.scene.json")
	if !scene_ok { fmt.eprintln("Could not load the Tanks scene"); return }
	if !load_tanks_game(&game_state, &world) {
		fmt.eprintln("Tanks scene requires one arena, one match, and two tanks")
		return
	}
	reset_match(&game_state)
	rune.run(&engine, on_update, on_draw)
}
