package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context
left: ecs.Entity

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		ok: bool
		bridge, ok = r3d_bridge.init("examples/skeletal_animation_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !ok { fmt.eprintln("Could not initialize R3D") }
	}
	left, _ = ecs.find_entity_by_id(world, "left")
}

update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	controls := rune.input_state(game)
	if input.pressed(controls, "pause") { ecs.pause_model_animation(world, left) }
	if input.pressed(controls, "resume") { ecs.resume_model_animation(world, left) }
	if input.pressed(controls, "bend") { ecs.transition_model_animation(world, left, "bend", 0.35) }
	if input.pressed(controls, "sway") { ecs.transition_model_animation(world, left, "sway", 0.35) }
	r3d_bridge.update_animations(&bridge, world, rune.asset_manager(game), game.delta_time)
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), {grid_slices = 16, grid_spacing = 1})
	example_text.draw("SKELETAL ANIMATION", 30, 25, 28, rl.RAYWHITE)
	example_text.draw("Shared model, independent R3D players: bend 1x / bend 0.5x / sway", 30, 66, 18, rl.LIGHTGRAY)
	example_text.draw("Left model: 1 bend   2 sway (0.35s blend)   P pause   R resume", 30, 94, 18, rl.LIGHTGRAY)
	if state, found := ecs.get_model_animation_state(world, left); found {
		example_text.draw(
			fmt.ctprintf("Left: %.2f / %.2f seconds   playing: %t", state.elapsed, state.duration, state.playing),
			30,
			rl.GetScreenHeight() - 45,
			18,
			rl.RAYWHITE,
		)
	}
}

shutdown :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

main :: proc() {
	game, ok := rune.init("examples/skeletal_animation_3d/project.json")
	if !ok { fmt.eprintln("Could not initialize skeletal animation example"); return }
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }
	if !rune.register_system(
		&game,
		{
			name = "skeletal_animation",
			start = start,
			update = update,
			draw = draw,
			shutdown = shutdown,
			on_scene_reloaded = start,
		},
	) { return }
	if !rune.run(&game) {
		fmt.eprintln(rune.last_scene_error())
	}
}
