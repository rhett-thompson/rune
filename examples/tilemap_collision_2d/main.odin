package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:render"

world: ecs.World
player: ecs.Entity

on_update :: proc(game: ^rune.Engine) {
	controller, has_controller := ecs.get_top_down_controller(&world, player)
	if !has_controller { return }
	controls := rune.input_state(game)
	move_x := input.axis(controls, "move_x")
	move_y := input.axis(controls, "move_y")
	if move_x != 0 || move_y != 0 {
		length := f32(math.sqrt(f64(move_x * move_x + move_y * move_y)))
		move_x /= length
		move_y /= length
	}
	ecs.move_top_down(&world, player, {move_x * controller.speed * game.delta_time, move_y * controller.speed * game.delta_time})
}

on_draw :: proc(game: ^rune.Engine) {
	render.draw_scene_2d(&world, rune.asset_manager(game))
	rune.draw_gizmos(game, &world)
}

main :: proc() {
	game, ok := rune.init("examples/tilemap_collision_2d/project.json")
	if !ok { fmt.eprintln("Could not load examples/tilemap_collision_2d/project.json"); return }
	defer rune.shutdown(&game)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/tilemap_collision_2d/scenes/main.scene.json")
	if !scene_ok { fmt.eprintln("Could not load the tilemap collision scene"); return }
	player, _ = ecs.find_entity_by_id(&world, "player")
	if player == ecs.Entity(0) { fmt.eprintln("Scene is missing entity ID: player"); return }
	rune.run(&game, on_update, on_draw)
}
