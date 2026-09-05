package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"

knight: ecs.Entity

initialize_tilemap :: proc(game: ^rune.Engine, world: ^ecs.World) {
	knight, _ = ecs.find_entity_by_id(world, "knight")
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	controller, has_controller := ecs.get_top_down_controller(world, knight)
	before, has_transform := ecs.get_transform(world, knight)
	if !has_controller || !has_transform {return}

	controls := rune.input_state(game)
	move_x := input.axis(controls, "move_x")
	move_y := input.axis(controls, "move_y")
	if move_x != 0 || move_y != 0 {
		length := f32(math.sqrt(f64(move_x * move_x + move_y * move_y)))
		move_x /= length
		move_y /= length
	}
	ecs.move_top_down(
		world,
		knight,
		{move_x * controller.speed * game.delta_time, move_y * controller.speed * game.delta_time},
	)
	after, _ := ecs.get_transform(world, knight)
	moving := after.position[0] != before.position[0] || after.position[1] != before.position[1]
	ecs.play_sprite_animation(world, knight, "run" if moving else "idle", false)
	if sprite, has_sprite := ecs.get_sprite_renderer(world, knight); has_sprite {
		if after.position[0] < before.position[0] {sprite.flip_x = true}
		if after.position[0] > before.position[0] {sprite.flip_x = false}
		ecs.set_sprite_renderer(world, knight, sprite)
	}
}
main :: proc() {
	game, ok := rune.init("examples/tilemap_2d/project.json")
	if !ok {fmt.eprintln("Could not load examples/tilemap_2d/project.json"); return}
	defer rune.shutdown(&game)

	if !rune.register_system(
		&game,
		{
			name = "tilemap_demo",
			start = initialize_tilemap,
			update = on_update,
			on_scene_reloaded = initialize_tilemap,
		},
	) {
		fmt.eprintln("Could not register tilemap system")
		return
	}
	if !rune.run(&game) {fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())}
}
