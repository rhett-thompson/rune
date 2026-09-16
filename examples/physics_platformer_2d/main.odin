package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"

player: ecs.Entity

control :: proc(game: ^rune.Engine, world: ^ecs.World) {
	controls := rune.input_state(game)
	ecs.character_controller_2d_move(world, player, input.axis(controls, "move_x"))
	if input.pressed(controls, "jump") {ecs.character_controller_2d_jump(world, player)}
	if input.released(controls, "jump") {ecs.character_controller_2d_release_jump(world, player)}
}

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	player, _ = ecs.find_entity_by_id(world, "player")
}

main :: proc() {
	game, ok := rune.init("examples/physics_platformer_2d/project.json")
	if !ok {fmt.eprintln("Could not load physics platformer project"); return}
	defer rune.shutdown(&game)
	if !rune.register_system(&game, {name = "platformer", start = start,
		on_scene_reloaded = start, fixed_update = control}) {return}
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
