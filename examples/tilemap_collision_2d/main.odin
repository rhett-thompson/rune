package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"

player: ecs.Entity

move_player :: proc(game: ^rune.Engine, world: ^ecs.World) {
	controller, has_controller := ecs.get_top_down_controller(world, player)
	if !has_controller { return }
	controls := rune.input_state(game)
	move_x := input.axis(controls, "move_x")
	move_y := input.axis(controls, "move_y")
	if move_x != 0 || move_y != 0 {
		length := f32(math.sqrt(f64(move_x * move_x + move_y * move_y)))
		move_x /= length
		move_y /= length
	}
	ecs.move_top_down(world, player, {move_x * controller.speed * game.delta_time, move_y * controller.speed * game.delta_time})
}

reacquire_player :: proc(game: ^rune.Engine, world: ^ecs.World) {
	player, _ = ecs.find_entity_by_id(world, "player")
}

main :: proc() {
	game, ok := rune.init("examples/tilemap_collision_2d/project.json")
	if !ok { fmt.eprintln("Could not load examples/tilemap_collision_2d/project.json"); return }
	defer rune.shutdown(&game)

	if !rune.register_system(&game, {name = "move_player", start = reacquire_player, update = move_player, on_scene_reloaded = reacquire_player}) {
		fmt.eprintln("Could not register tilemap collision systems")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
