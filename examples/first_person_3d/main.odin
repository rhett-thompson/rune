package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

world: ecs.World
bridge: r3d_bridge.Context
player: ecs.Entity
camera_yaw: f32 = 180
camera_pitch: f32
cursor_captured := true

scene_view := r3d_bridge.Scene3D_Settings{grid_slices = 24, grid_spacing = 1, draw_colliders = true}

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
	if !r3d_bridge.draw_scene_ex(&bridge, &world, rune.asset_manager(game), scene_view) {
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

	bridge_ok: bool
	bridge, bridge_ok = r3d_bridge.init("examples/first_person_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
	if !bridge_ok {
		fmt.eprintln("Could not initialize r3d")
		return
	}
	defer r3d_bridge.shutdown(&bridge)

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
