package main

import "core:fmt"
import "core:os"
import rune "rune:core"
import "rune:ecs"
import rl "vendor:raylib"

skeleton: ecs.Entity
direction: f32 = 1
capture_mode: bool
capture_frame: int

initialize_tilemap :: proc(game: ^rune.Engine, world: ^ecs.World) {
	skeleton, _ = ecs.find_entity_by_id(world, "skeleton")
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	transform, found := ecs.get_transform(world, skeleton)
	if !found {return}
	transform.position[0] += direction * 110 * game.delta_time
	if transform.position[0] < 64 || transform.position[0] > 896 {direction = -direction}
	ecs.set_transform(world, skeleton, transform)
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if capture_mode && capture_frame == 30 {
		rl.TakeScreenshot("build/tilemap_2d_capture.png")
	}
	capture_frame += 1
	if capture_mode && capture_frame > 32 {rune.request_exit(game)}
}

main :: proc() {
	capture_mode = len(os.args) > 1 && os.args[1] == "--capture"
	game, ok := rune.init("examples/tilemap_2d/project.json")
	if !ok {fmt.eprintln("Could not load examples/tilemap_2d/project.json"); return}
	defer rune.shutdown(&game)

	if !rune.register_system(
		&game,
		{
			name = "tilemap_demo",
			start = initialize_tilemap,
			update = on_update,
			draw = on_draw,
			on_scene_reloaded = initialize_tilemap,
		},
	) {
		fmt.eprintln("Could not register tilemap system")
		return
	}
	if !rune.run(&game) {fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())}
}
