package main

import example_text "../shared/text"

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context
left: ecs.Entity
footsteps, impacts: int
foot_age, impact_age: f32 = -1, -1
impact_position: rl.Vector3
last_marker: string = "none"
speed_index := 1
speeds := [?]f32{0.5, 1, 2}

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		ok: bool
		bridge, ok = r3d_bridge.init("examples/skeletal_animation_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !ok { fmt.eprintln("Could not initialize R3D") }
	}
	left, _ = ecs.find_entity_by_id(world, "left")
	footsteps, impacts = 0, 0
	foot_age, impact_age = -1, -1
	last_marker = "none"
}

update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	controls := rune.input_state(game)
	if input.pressed(controls, "pause") { ecs.pause_model_animation(world, left) }
	if input.pressed(controls, "resume") { ecs.resume_model_animation(world, left) }
	if input.pressed(controls, "bend") { ecs.transition_model_animation(world, left, "bend", 0.35) }
	if input.pressed(controls, "sway") { ecs.transition_model_animation(world, left, "sway", 0.35) }
	animator, _ := ecs.get_model_animator(world, left)
	if input.pressed(controls, "speed") {
		speed_index = (speed_index + 1) % len(speeds)
		animator.speed = speeds[speed_index] * (-1 if animator.speed < 0 else 1)
		ecs.set_model_animator(world, left, animator)
	}
	if input.pressed(controls, "reverse") {
		animator.speed = -animator.speed
		ecs.set_model_animator(world, left, animator)
	}
	if input.pressed(controls, "seek") {ecs.seek_model_animation(world, left, 1)}
	if foot_age >= 0 {foot_age += game.delta_time; if foot_age > 0.4 {foot_age = -1}}
	if impact_age >= 0 {impact_age += game.delta_time; if impact_age > 0.5 {impact_age = -1}}
	r3d_bridge.update_animations(&bridge, world, rune.asset_manager(game), game.delta_time)
}

post_animation :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for event in ecs.model_animation_events(world) {
		if event.entity != left {continue}
		switch event.name {
		case "footstep":
			footsteps += 1
			foot_age = 0
			last_marker = "footstep"
			rune.play_audio(game, world, left, "step")
		case "impact":
			impacts += 1
			impact_age = 0
			last_marker = "impact"
			impact_position = {-3.1 if event.time < 1 else -0.9, 1.25, 0.3}
			rune.play_audio(game, world, left, "impact")
		}
	}
}

event_status :: proc(dev: ^console.Console, arguments: string) {
	console.set_result(dev, struct{footsteps, impacts: int, last_marker: string}{footsteps, impacts, last_marker})
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), {grid_slices = 16, grid_spacing = 1})
	entity, camera, found := ecs.active_camera_3d(world)
	if found {
		pose, _ := ecs.get_transform(world, entity)
		rl.BeginMode3D({position = transmute(rl.Vector3)pose.position, target = transmute(rl.Vector3)camera.target, up = transmute(rl.Vector3)camera.up, fovy = camera.fovy, projection = .PERSPECTIVE})
		if foot_age >= 0 {rl.DrawCircle3D({-2, 0.03, 0}, 0.25 + foot_age * 2, {1, 0, 0}, 90, rl.SKYBLUE)}
		if impact_age >= 0 {
			for i in 0 ..< 12 {
				angle := f32(i) * math.TAU / 12
				position := impact_position + rl.Vector3{math.cos(angle) * impact_age * 2, math.sin(angle) * impact_age * 2 - impact_age * impact_age, 0}
				rl.DrawSphere(position, 0.055 * (1 - impact_age / 0.5), rl.GOLD)
			}
		}
		rl.EndMode3D()
	}
	example_text.draw("SKELETAL ANIMATION", 30, 25, 28, rl.RAYWHITE)
	example_text.draw("Shared model, independent R3D players: bend 1x / bend 0.5x / sway", 30, 66, 18, rl.LIGHTGRAY)
	example_text.draw("Left model: 1 bend   2 sway (0.35s blend)   P pause   R resume", 30, 94, 18, rl.LIGHTGRAY)
	example_text.draw("S speed   V reverse   H seek to 1s (silent)", 30, 122, 18, rl.LIGHTGRAY)
	animator, _ := ecs.get_model_animator(world, left)
	example_text.draw(fmt.ctprintf("Markers: footsteps %d / impacts %d   Last: %s   Speed: %.1fx", footsteps, impacts, last_marker, animator.speed), 30, 153, 20, rl.GOLD)
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
	console.register(rune.developer_console(&game), "clip_events", "Read skeletal marker effect counters.", event_status)
	if !rune.register_system(
		&game,
		{
			name = "skeletal_animation",
			start = start,
			update = update,
			post_animation = post_animation,
			draw = draw,
			shutdown = shutdown,
			on_scene_reloaded = start,
		},
	) { return }
	if !rune.run(&game) {
		fmt.eprintln(rune.last_scene_error())
	}
}
