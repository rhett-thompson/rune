package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:render"

world: ecs.World
skeleton: ecs.Entity
direction: f32 = 1

on_update :: proc(game: ^rune.Engine) {
	transform, found := ecs.get_transform(&world, skeleton)
	if !found { return }
	transform.position[0] += direction * 110 * game.delta_time
	if transform.position[0] < 64 || transform.position[0] > 896 { direction = -direction }
	ecs.set_transform(&world, skeleton, transform)
}

on_draw :: proc(game: ^rune.Engine) {
	render.draw_scene_2d(&world, rune.asset_manager(game))
}

main :: proc() {
	game, ok := rune.init("examples/tilemap_2d/project.json")
	if !ok { fmt.eprintln("Could not load examples/tilemap_2d/project.json"); return }
	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/tilemap_2d/scenes/main.scene.json")
	if !scene_ok { fmt.eprintln("Could not load the tilemap scene"); rune.shutdown(&game); return }
	skeleton, _ = ecs.find_entity_by_id(&world, "skeleton")
	if skeleton == ecs.Entity(0) { fmt.eprintln("Scene is missing entity ID: skeleton"); rune.shutdown(&game); return }
	rune.run(&game, on_update, on_draw)
}
