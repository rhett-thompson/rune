package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"

skeleton: ecs.Entity
direction: f32 = 1

initialize_tilemap :: proc(game: ^rune.Engine, world: ^ecs.World) {
	skeleton, _ = ecs.find_entity_by_id(world, "skeleton")
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	transform, found := ecs.get_transform(world, skeleton)
	if !found { return }
	transform.position[0] += direction * 110 * game.delta_time
	if transform.position[0] < 64 || transform.position[0] > 896 { direction = -direction }
	ecs.set_transform(world, skeleton, transform)
}

main :: proc() {
	game, ok := rune.init("examples/tilemap_2d/project.json")
	if !ok { fmt.eprintln("Could not load examples/tilemap_2d/project.json"); return }
	defer rune.shutdown(&game)

	if !rune.register_system(&game, {
		name = "tilemap_demo",
		start = initialize_tilemap,
		update = on_update,
		on_scene_reloaded = initialize_tilemap,
	}) {
		fmt.eprintln("Could not register tilemap system")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
