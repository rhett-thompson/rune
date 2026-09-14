package main

import "core:fmt"
import "core:math"
import example_text "../shared/text"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

TrainingTarget :: struct { health: int }

knight, target, dust, impact: ecs.Entity
speed_index := 1
speeds := [?]f32{0.5, 1, 2, 4}
paused: bool
steps, hits: int
flash: f32
last_event: string = "none"

initialize :: proc(game: ^rune.Engine, world: ^ecs.World) {
	knight, _ = ecs.find_entity_by_id(world, "knight")
	target, _ = ecs.find_entity_by_id(world, "target")
	dust, _ = ecs.find_entity_by_id(world, "dust")
	impact, _ = ecs.find_entity_by_id(world, "impact")
	steps, hits, flash = 0, 0, 0
	paused = false
	last_event = "none"
}

update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	controls := rune.input_state(game)
	if input.pressed(controls, "speed") {speed_index = (speed_index + 1) % len(speeds)}
	animator, _ := ecs.get_sprite_animator(world, knight)
	animator.speed = speeds[speed_index]
	ecs.set_sprite_animator(world, knight, animator)
	if input.pressed(controls, "pause_animation") {
		paused = !paused
		if paused {ecs.pause_sprite_animation(world, knight)} else {ecs.resume_sprite_animation(world, knight)}
	}
	if input.pressed(controls, "reset") {
		ecs.set(world, target, TrainingTarget{100})
		hits = 0
	}
	flash = max(0, flash - game.delta_time)
	if paused {return}
	state, _ := ecs.get_sprite_animation_state(world, knight)
	if animator.clip == "strike" && !state.finished {return}
	if input.pressed(controls, "attack") {
		ecs.play_sprite_animation(world, knight, "strike")
		ecs.queue_sprite_animation(world, knight, "idle")
		return
	}
	x := input.axis(controls, "move_x")
	transform, _ := ecs.get_transform(world, knight)
	transform.position[0] = math.clamp(transform.position[0] + x * 120 * speeds[speed_index] * game.delta_time, 140, 520)
	ecs.set_transform(world, knight, transform)
	ecs.play_sprite_animation(world, knight, "run" if x != 0 else "idle", restart = false)
}

// All gameplay reactions happen here, after the animation advances. Markers
// have no hardcoded engine meaning; this game's Odin code chooses the behavior.
post_animation :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for event in ecs.sprite_animation_events(world) {
		if event.entity != knight {continue}
		switch event.name {
		case "footstep":
			last_event = "footstep"
			steps += 1
			rune.play_audio(game, world, knight, "step")
			pose, _ := ecs.get_transform(world, knight)
			pose.position[1] += 47
			pose.scale = {1, 1, 1}
			ecs.set_transform(world, dust, pose)
			ecs.emit_particles_2d(world, dust, 5)
		case "impact":
			last_event = "impact (miss)"
			pose, _ := ecs.get_transform(world, knight)
			target_pose, _ := ecs.get_transform(world, target)
			stats, _ := ecs.get(world, target, TrainingTarget)
			if math.abs(target_pose.position[0] - pose.position[0]) <= 150 && stats.health > 0 {
				stats.health = max(0, stats.health - 10)
				ecs.set(world, target, stats)
				hits += 1
				flash = 0.18
				last_event = "impact (10 damage)"
				rune.play_audio(game, world, knight, "impact")
				ecs.emit_particles_2d(world, impact, 24)
			}
		}
	}
}

draw_background :: proc(game: ^rune.Engine, world: ^ecs.World) {
	rl.DrawRectangle(60, 160, 840, 276, {24, 33, 47, 255})
	rl.DrawLine(80, 378, 880, 378, {80, 98, 118, 255})
	if flash > 0 {rl.DrawCircle(650, 330, 68, {255, 192, 94, 90})}
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	example_text.draw("Animation events", 36, 24, 30, rl.RAYWHITE)
	example_text.draw("A/D: walk   Space: roll strike   Tab: speed   P: pause clip   R: reset target", 36, 70, 18, rl.LIGHTGRAY)
	example_text.draw(fmt.ctprintf("Speed %.1fx  |  %s  |  Footsteps %d  |  Hits %d", speeds[speed_index], "paused" if paused else "playing", steps, hits), 36, 110, 20, rl.RAYWHITE)
	stats, _ := ecs.get(world, target, TrainingTarget)
	example_text.draw(fmt.ctprintf("Target: %d / 100", stats.health), 575, 205, 20, rl.GOLD)
	example_text.draw("Walk close, then strike", 552, 239, 16, rl.LIGHTGRAY)
	example_text.draw(fmt.ctprintf("Last marker: %s", last_event), 36, 465, 20, rl.RAYWHITE)
	example_text.draw("Footsteps, damage, and particles follow clip frames at every speed.", 36, 502, 18, rl.LIGHTGRAY)
}

main :: proc() {
	game, ok := rune.init("examples/animation_events_2d/project.json")
	if !ok {fmt.eprintln("Could not load animation-events project"); return}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) {return}
	if !ecs.register_component(rune.component_registry(&game), "TrainingTarget", TrainingTarget, TrainingTarget{100}) {return}
	if !rune.register_system(&game, {
		name = "animation_events", start = initialize, update = update,
		post_animation = post_animation, pre_draw = draw_background, draw = draw,
		on_scene_reloaded = initialize,
	}) {return}
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
