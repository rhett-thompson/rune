package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"

game_state: Tanks_Game

register_tanks_components :: proc(game: ^rune.Engine) -> bool {
	registry := rune.component_registry(game)
	return ecs.register_component(registry, "TanksArena", Tanks_Arena, Tanks_Arena{}, "Tank arena dimensions, walls, and presentation") &&
	       ecs.register_component(registry, "Tank", Tank, Tank{}, "Player or computer controlled tank") &&
	       ecs.register_component(registry, "TanksMatch", Tanks_Match, Tanks_Match{}, "Tank match scoring and round state")
}

on_update :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) { update_tanks(&game_state, engine, scene_world) }
on_draw :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) { draw_tanks(&game_state) }
on_start :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	if load_tanks_game(&game_state, scene_world) { reset_match(&game_state) }
}
on_reload :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	destroy_tanks_game(&game_state)
	on_start(engine, scene_world)
}
on_shutdown :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) { destroy_tanks_game(&game_state) }

main :: proc() {
	engine, ok := rune.init("examples/tanks/project.json")
	if !ok { fmt.eprintln("Could not load examples/tanks/project.json"); return }
	defer rune.shutdown(&engine)
	if !register_tanks_components(&engine) { fmt.eprintln("Could not register Tanks components"); return }

	if !rune.register_system(&engine, {
		name = "tanks",
		start = on_start,
		update = on_update,
		draw = on_draw,
		on_scene_reloaded = on_reload,
		shutdown = on_shutdown,
	}) {
		fmt.eprintln("Could not register the Tanks system")
		return
	}
	if !rune.run(&engine) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
