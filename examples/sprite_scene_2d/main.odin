package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import rl "vendor:raylib"

Skeleton_Size  : f32 : 32
Skeleton_Speed : f32 : 140

skeleton:           ecs.Entity
movement_direction: [2]f32
direction_timer:    f32

initialize_sprite_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	skeleton, _ = ecs.find_entity_by_id(world, "skeleton")
	movement_direction = {1, 1}
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
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

	transform, found := ecs.get_transform(world, skeleton)
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
	ecs.set_transform(world, skeleton, transform)
}

draw_background :: proc(game: ^rune.Engine, world: ^ecs.World) {
	draw_tiled_walls(world, rune.asset_manager(game))
}

main :: proc() {
	game, ok := rune.init("examples/sprite_scene_2d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/sprite_scene_2d/project.json")
		return
	}
	defer rune.shutdown(&game)
	if !ecs.register_component(
		rune.component_registry(&game),
		"TiledWall",
		Tiled_Wall,
		Tiled_Wall{tile_scale = 1},
		"Repeated full-screen texture background",
	) {
		fmt.eprintln("Could not register TiledWall")
		return
	}

	if !rune.register_system(&game, {
		name = "sprite_scene",
		start = initialize_sprite_scene,
		update = on_update,
		pre_draw = draw_background,
		on_scene_reloaded = initialize_sprite_scene,
	}) {
		fmt.eprintln("Could not register sprite-scene system")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
