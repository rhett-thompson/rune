package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:render"
import rl "vendor:raylib"

world: ecs.World
listener_entity: ecs.Entity
player_entity: ecs.Entity
last_play_succeeded: bool
bell_phase: f32

scene_view := render.Scene3D_Settings{grid_slices = 40, grid_spacing = 1}

play_bell_on_click :: proc(game: ^rune.Engine, scene_world: ^ecs.World) {
	// Move the emitting sphere from two to thirty units away from the listener,
	// then back again. The audio runtime reads this Transform each frame.
	bell_phase += game.delta_time * 0.65
	distance := 16 + 14 * f32(math.sin(f64(bell_phase)))
	if transform, found := ecs.get_transform(scene_world, player_entity); found {
		transform.position = {distance, 1.6, 5}
		ecs.set_transform(scene_world, player_entity, transform)
	}
	if input.pressed(rune.input_state(game), "play_bell") {
		last_play_succeeded = rune.play_audio(game, scene_world, player_entity)
	}
}

draw_audio_components :: proc(game: ^rune.Engine, scene_world: ^ecs.World) {
	listener, listener_found := ecs.get_audio_listener(scene_world, listener_entity)
	player, player_found := ecs.get_audio_player(scene_world, player_entity)
	if !listener_found || !player_found {
		rl.DrawText("Audio component data is missing", 24, 24, 28, rl.MAROON)
		return
	}

	render.draw_scene_3d(scene_world, scene_view)
	rl.DrawText("Rune Audio Components", 24, 24, 30, rl.DARKGRAY)
	rl.DrawText("AudioListener is attached to the Camera3D entity.", 24, 78, 20, rl.GRAY)
	rl.DrawText("AudioPlayer is attached to the moving orange sphere.", 24, 108, 20, rl.GRAY)
	if listener.active {
		rl.DrawText("Listener: active", 24, 164, 22, rl.DARKGREEN)
	} else {
		rl.DrawText("Listener: inactive", 24, 164, 22, rl.MAROON)
	}
	rl.DrawText("Sphere moves away from and returns to the listener.", 24, 198, 22, rl.DARKBLUE)
	rl.DrawText("Left-click to play the spatial bell.", 24, 256, 18, rl.GRAY)
	if last_play_succeeded {
		rl.DrawText("Playing", 24, 282, 18, rl.DARKGREEN)
	}
	rl.DrawFPS(24, 312)
}

main :: proc() {
	game, ok := rune.init("examples/audio_components/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/audio_components/project.json")
		return
	}
	defer rune.shutdown(&game)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/audio_components/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the audio-components scene")
		return
	}

	listener_entity, ok = ecs.find_entity_by_id(&world, "main_camera")
	if !ok {
		fmt.eprintln("Scene is missing entity ID: main_camera")
		return
	}
	player_entity, ok = ecs.find_entity_by_id(&world, "bell_sphere")
	if !ok {
		fmt.eprintln("Scene is missing entity ID: bell_sphere")
		return
	}

	if !rune.register_system(&game, rune.System{name = "play_bell_on_click", update = play_bell_on_click}) ||
		!rune.register_system(&game, rune.System{name = "draw_audio_components", draw = draw_audio_components}) {
		fmt.eprintln("Could not register the audio-components draw system")
		return
	}
	rune.run_scene(&game, &world)
}
