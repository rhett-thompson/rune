package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:render"
import rl "vendor:raylib"

scene_view := render.Scene3D_Settings{
	grid_slices = 20,
	grid_spacing = 1.0,
}

world: ecs.World
cube: ecs.Entity

on_update :: proc(game: ^rune.Engine) {
	transform, found := ecs.get_transform(&world, cube)
	if found {
		transform.rotation[0] += 19.25 * game.delta_time
		transform.rotation[1] += 55.0 * game.delta_time
		ecs.set_transform(&world, cube, transform)
	}
}

on_draw :: proc(game: ^rune.Engine) {
	if !render.draw_scene_3d(&world, scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rune.draw_gizmos(game, &world)
	rl.DrawText("Rune 3D Hello World", 24, 24, 28, rl.RAYWHITE)
	rl.DrawText("A JSON scene with a rotating cube", 24, 60, 18, rl.LIGHTGRAY)
	rl.DrawFPS(24, 94)
}

main :: proc() {

	game, ok := rune.init("examples/hello_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/hello_3d/project.json")
		return
	}
	defer rune.shutdown(&game)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/hello_3d/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the 3D hello-world scene")
		return
	}

	found: bool
	cube, found = ecs.find_entity_by_id(&world, "cube")
	if !found {
		fmt.eprintln("Scene is missing entity ID: cube")
		return
	}

	rune.run(&game, on_update, on_draw)
	
}
