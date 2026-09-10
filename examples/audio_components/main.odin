package main

import example_text "../shared/text"

import "core:fmt"
import "core:math"
import "rune:audio"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context
listener_entity: ecs.Entity
player_entity: ecs.Entity
last_play_succeeded: bool
bell_phase: f32

scene_view := r3d_bridge.Scene3D_Settings {
	grid_slices  = 40,
	grid_spacing = 1,
}

initialize_audio_components :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		bridge_ok: bool
		bridge, bridge_ok = r3d_bridge.init("examples/audio_components", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !bridge_ok { fmt.eprintln("Could not initialize r3d") }
	}
	listener_entity, _ = ecs.find_entity_by_id(world, "main_camera")
	player_entity, _ = ecs.find_entity_by_id(world, "bell_sphere")
}

shutdown_audio_components :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

play_bell_on_click :: proc(game: ^rune.Engine, scene_world: ^ecs.World) {
	controls := rune.input_state(game)
	if input.pressed(
		controls,
		"mute_sfx",
	) { audio.mute_bus(&game.audio.mixer, .sfx, !game.audio.mixer.buses[.sfx].muted) }
	if input.pressed(controls, "fade_sfx") { audio.fade_bus(&game.audio.mixer, .sfx, 0, 2) }
	if input.pressed(controls, "restore_sfx") { audio.set_bus_volume(&game.audio.mixer, .sfx, 1) }
	// Move the emitting sphere from two to thirty units away from the listener,
	// then back again. The audio runtime reads this Transform each frame.
	bell_phase += game.delta_time * 0.65
	distance := 16 + 14 * f32(math.sin(f64(bell_phase)))
	if transform, found := ecs.get_transform(scene_world, player_entity); found {
		transform.position = {distance, 1.6, 5}
		ecs.set_transform(scene_world, player_entity, transform)
	}
	if input.pressed(rune.input_state(game), "play_bell") {
		last_play_succeeded = rune.play_audio(game, scene_world, player_entity, "bell")
	}
}

draw_audio_components :: proc(game: ^rune.Engine, scene_world: ^ecs.World) {
	listener, listener_found := ecs.get_audio_listener(scene_world, listener_entity)
	player, player_found := ecs.get_audio_player(scene_world, player_entity, "bell")
	if !listener_found || !player_found {
		example_text.draw("Audio component data is missing", 24, 24, 28, rl.MAROON)
		return
	}

	r3d_bridge.draw_scene_ex(&bridge, scene_world, rune.asset_manager(game), scene_view)
	example_text.draw("Rune Audio Components", 24, 24, 30, rl.DARKGRAY)
	example_text.draw("AudioListener is attached to the Camera3D entity.", 24, 78, 20, rl.GRAY)
	example_text.draw("AudioPlayer is attached to the moving orange sphere.", 24, 108, 20, rl.GRAY)
	if listener.active {
		example_text.draw("Listener: active", 24, 164, 22, rl.DARKGREEN)
	} else {
		example_text.draw("Listener: inactive", 24, 164, 22, rl.MAROON)
	}
	example_text.draw("Sphere moves away from and returns to the listener.", 24, 198, 22, rl.DARKBLUE)
	example_text.draw("Left-click to play the spatial bell.", 24, 256, 18, rl.GRAY)
	if last_play_succeeded {
		example_text.draw("Playing", 24, 282, 18, rl.DARKGREEN)
	}
	rl.DrawFPS(24, 312)
	example_text.draw(
		fmt.ctprintf(
			"SFX bus %.0f%%   muted: %t | M mute  F fade  R restore",
			game.audio.mixer.buses[.sfx].volume * 100,
			game.audio.mixer.buses[.sfx].muted,
		),
		24,
		350,
		18,
		rl.DARKGRAY,
	)
}

main :: proc() {
	game, ok := rune.init("examples/audio_components/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/audio_components/project.json")
		return
	}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }

	if !rune.register_system(
		   &game,
		   rune.System {
			   name = "play_bell_on_click",
			   start = initialize_audio_components,
			   update = play_bell_on_click,
			   on_scene_reloaded = initialize_audio_components,
			   shutdown = shutdown_audio_components,
		   },
	   ) ||
	   !rune.register_system(&game, rune.System{name = "draw_audio_components", draw = draw_audio_components}) {
		fmt.eprintln("Could not register the audio-components draw system")
		return
	}
	if !rune.run(&game) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
