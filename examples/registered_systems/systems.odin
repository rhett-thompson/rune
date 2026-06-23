package main

import rune "rune:core"
import "rune:ecs"
import "rune:render"
import rl "vendor:raylib"

demo_skeleton: ecs.Entity
movement: [2]f32 = {1, 1}

skeleton_movement_system :: proc(game: ^rune.Engine, world: ^ecs.World) {
	transform, found := ecs.get_transform(world, demo_skeleton)
	if !found { return }
	transform.position[0] += movement[0] * 140 * game.delta_time
	transform.position[1] += movement[1] * 140 * game.delta_time
	if transform.position[0] < 16 || transform.position[0] > f32(rl.GetScreenWidth()) - 16 { movement[0] = -movement[0] }
	if transform.position[1] < 16 || transform.position[1] > f32(rl.GetScreenHeight()) - 16 { movement[1] = -movement[1] }
	ecs.set_transform(world, demo_skeleton, transform)
}

scene_draw_system :: proc(game: ^rune.Engine, world: ^ecs.World) {
	render.draw_scene_2d(world, rune.asset_manager(game))
	rl.DrawText("Registered systems: movement, draw, and reload notification", 24, 24, 20, rl.RAYWHITE)
}

reacquire_demo_entities :: proc(game: ^rune.Engine, world: ^ecs.World) {
	demo_skeleton, _ = ecs.find_entity_by_id(world, "skeleton")
}
