package main

import "core:fmt"
import "rune:console"
import rune "rune:core"
import "rune:profile"

command_calls: int
test_command :: proc(dev: ^console.Console, arguments: string) {command_calls += 1}

main :: proc() {
	assert(rune.Player_Build == profile.Player_Build)
	project, loaded := rune.load_project("tools/player_profile_validation/project.json")
	assert(loaded)
	defer rune.destroy_project(&project)
	assert(project.window.show_fps == !rune.Player_Build)
	assert(project.hot_reload.enabled == !rune.Player_Build)
	assert(project.gizmos.enabled == !rune.Player_Build)
	assert(project.gizmos.navmeshes == !rune.Player_Build)

	dev := console.init()
	registered := console.register(&dev, "test", "Profile test command.", test_command)
	assert(registered == !rune.Player_Build)
	assert(console.execute(&dev, "test") == !rune.Player_Build)
	assert(command_calls == (0 if rune.Player_Build else 1))

	when rune.Player_Build {
		assert(dev.command_count == 0)
		// Refuse direct API callers as well as the engine-owned command line.
		assert(!console.enable_remote(&dev, "build/player-profile-inbox-must-not-exist"))
		assert(dev.remote.directory_len == 0)
		dev.commands[0].name_len = 4
		copy(dev.commands[0].name[:], "test")
		dev.commands[0].handler = test_command
		dev.command_count = 1
		assert(!console.execute(&dev, "test") && command_calls == 0)
		dev.is_open = true
		assert(!console.is_open(&dev))
		console.update(&dev)
		assert(!dev.is_open)
		console.draw(&dev)
		console.draw_view(&dev)
		console.error(&dev, "Expected player diagnostic; log history remains available.")
		assert(dev.error_count == 1 && dev.line_count == 1)

		// Mutating public settings cannot enable polling/drawing or console pause.
		engine := rune.Engine{console = dev, delta_time = 1, fixed_delta_time = 1.0/60.0}
		engine.project.hot_reload.enabled = true
		engine.project.hot_reload.scenes = true
		engine.project.window.show_fps = true
		engine.gizmos.enabled = true
		engine.gizmos.navmeshes = true
		engine.hot_reload_due = true
		engine.debug.paused = true
		engine.debug.steps_remaining = 2
		assert(!rune.hot_reload_poll_due(&engine))
		assert(!rune.reload_scene_if_changed(&engine, nil, "missing.scene.json"))
		rune.draw_gizmos(&engine, nil)
		rune.update_fps_title(&engine)
		assert(!rune.is_paused(&engine) && rune.debug_simulation_tick(&engine))
		assert(engine.delta_time == 1)
		rune.set_paused(&engine, true)
		assert(rune.is_paused(&engine) && !rune.debug_simulation_tick(&engine))
		rune.set_paused(&engine, false)
		assert(!rune.is_paused(&engine) && rune.debug_simulation_tick(&engine))
	}
	fmt.printf("Player profile validation passed (RUNE_PLAYER=%t).\n", rune.Player_Build)
}
