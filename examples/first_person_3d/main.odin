package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:render"
import rl "vendor:raylib"

world: ecs.World
player: ecs.Entity
camera_yaw: f32 = 180
camera_pitch: f32
cursor_captured := true

scene_view := render.Scene3D_Settings{grid_slices = 24, grid_spacing = 1, draw_colliders = true}

on_update :: proc(game: ^rune.Engine) {
	controls := rune.input_state(game)
	if input.pressed(controls, "toggle_cursor") {
		cursor_captured = !cursor_captured
		if cursor_captured { rl.DisableCursor() } else { rl.EnableCursor() }
	}
	if cursor_captured {
		first_person_controller_system(&world, player, controls, &camera_yaw, &camera_pitch, game.delta_time)
	}
}

on_draw :: proc(game: ^rune.Engine) {
	if !render.draw_scene_3d(&world, scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rune.draw_gizmos(game, &world)
	rl.DrawText("Rune First Person Controller", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("WASD: move   Space: jump   Shift: sprint   Escape: release/capture mouse", 24, 60, 18, rl.DARKGRAY)
	rl.DrawText("Static box collision and gravity use the Gameplay layer.", 24, 86, 18, rl.GRAY)
	rl.DrawFPS(24, 112)
}

main :: proc() {
	game, ok := rune.init("examples/first_person_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/first_person_3d/project.json")
		return
	}
	defer rune.shutdown(&game)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/first_person_3d/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the first-person scene")
		return
	}
	found: bool
	player, found = ecs.find_entity_by_id(&world, "player")
	if !found {
		fmt.eprintln("Scene is missing entity ID: player")
		return
	}

	rl.DisableCursor()
	rune.run(&game, on_update, on_draw)
}
