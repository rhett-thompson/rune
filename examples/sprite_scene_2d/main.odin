package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:render"
import rl "vendor:raylib"

Skeleton_Size  : f32 : 32
Skeleton_Speed : f32 : 140

world:              ecs.World
skeleton:           ecs.Entity
movement_direction: [2]f32
direction_timer:    f32

on_update :: proc(game: ^rune.Engine) {
	direction_timer -= game.delta_time
	if direction_timer <= 0 {
		movement_direction = {
			f32(rl.GetRandomValue(-1, 1)),
			f32(rl.GetRandomValue(-1, 1)),
		}
		if movement_direction == {0, 0} {
			movement_direction[0] = 1
		}
		direction_timer = f32(rl.GetRandomValue(4, 12)) / 10
	}

	transform, found := ecs.get_transform(&world, skeleton)
	if !found { return }
	transform.position[0] += movement_direction[0] * Skeleton_Speed * game.delta_time
	transform.position[1] += movement_direction[1] * Skeleton_Speed * game.delta_time

	half_size := Skeleton_Size * 0.5
	if transform.position[0] < half_size {
		transform.position[0] = half_size
		movement_direction[0] = 1
	} else if transform.position[0] > f32(rl.GetScreenWidth()) - half_size {
		transform.position[0] = f32(rl.GetScreenWidth()) - half_size
		movement_direction[0] = -1
	}
	if transform.position[1] < half_size {
		transform.position[1] = half_size
		movement_direction[1] = 1
	} else if transform.position[1] > f32(rl.GetScreenHeight()) - half_size {
		transform.position[1] = f32(rl.GetScreenHeight()) - half_size
		movement_direction[1] = -1
	}
	ecs.set_transform(&world, skeleton, transform)
}

on_draw :: proc(game: ^rune.Engine) {
	draw_tiled_walls(&world, rune.asset_manager(game))
	render.draw_scene_2d(&world, rune.asset_manager(game))
}

main :: proc() {
	game, ok := rune.init("examples/sprite_scene_2d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/sprite_scene_2d/project.json")
		return
	}
	defer rune.shutdown(&game)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/sprite_scene_2d/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the sprite scene")
		return
	}
	skeleton, scene_ok = ecs.find_entity_by_id(&world, "skeleton")
	if !scene_ok {
		fmt.eprintln("Could not find the skeleton entity")
		return
	}
	movement_direction = {1, 1}

	rune.run(&game, on_update, on_draw)
}
