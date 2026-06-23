package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:render"
import rl "vendor:raylib"

scene_view := render.Scene3D_Settings{grid_slices = 20, grid_spacing = 1}
world: ecs.World
pyramid: ecs.Entity

on_update :: proc(game: ^rune.Engine) {
	if rune.reload_scene_if_changed(game, &world, "examples/model_scene_3d/scenes/main.scene.json") {
		pyramid, _ = ecs.find_entity_by_id(&world, "pyramid")
	}
	transform, found := ecs.get_transform(&world, pyramid)
	if !found { return }
	transform.rotation[1] += 45 * game.delta_time
	ecs.set_transform(&world, pyramid, transform)
}

on_draw :: proc(game: ^rune.Engine) {
	if !render.draw_scene_3d_with_assets(&world, rune.asset_manager(game), scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rl.DrawText("Rune Model Scene 3D", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("An OBJ model loaded from scene JSON", 24, 60, 18, rl.GRAY)
	rl.DrawFPS(24, 94)
}

main :: proc() {
	game, ok := rune.init("examples/model_scene_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/model_scene_3d/project.json")
		return
	}
	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/model_scene_3d/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the model scene")
		rune.shutdown(&game)
		return
	}
	pyramid, _ = ecs.find_entity_by_id(&world, "pyramid")
	if pyramid == ecs.Entity(0) {
		fmt.eprintln("Scene is missing entity ID: pyramid")
		rune.shutdown(&game)
		return
	}
	rune.run(&game, on_update, on_draw)
}
