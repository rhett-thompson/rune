package main

import example_text "../shared/text"

import "core:fmt"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if console.is_open(rune.developer_console(game)) { return }
	controls := rune.input_state(game)
	burst, _ := ecs.find_entity_by_id(world, "burst")
	if input.pressed(controls, "burst") { ecs.emit_particles_2d(world, burst, 160) }
	if input.pressed(controls, "toggle") {
		emitters := []string{"fountain", "smoke"}
		for id in emitters {
			entity, _ := ecs.find_entity_by_id(world, id)
			emitter, _ := ecs.get(world, entity, ecs.ParticleEmitter2D)
			emitter.emitting = !emitter.emitting
			ecs.set(world, entity, emitter)
		}
	}
	if input.pressed(controls, "clear") {
		for entity in ecs.query(world, ecs.ParticleEmitter2D) { ecs.clear_particles_2d(world, entity) }
	}
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	example_text.draw("Particles", 40, 30, 30, {230, 238, 250, 255})
	example_text.draw("SPACE burst     E toggle emitters     C clear     F3 gizmos", 40, 77, 18, {150, 164, 189, 255})
	example_text.draw("Fountain", 123, 460, 20, {255, 204, 121, 255})
	example_text.draw("Textured smoke", 391, 460, 20, {155, 194, 225, 255})
	example_text.draw("Burst", 704, 460, 20, {140, 236, 210, 255})
	count := 0
	for entity in ecs.query(world, ecs.ParticleEmitter2D) { count += ecs.particle_count_2d(world, entity) }
	label := fmt.ctprintf("%d live particles", count)
	example_text.draw(label, 40, 507, 16, {123, 138, 165, 255})
}

main :: proc() {
	game, ok := rune.init("examples/particles_2d/project.json")
	if !ok { fmt.eprintln("Could not initialize particle example"); return }
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }
	if !rune.register_system(&game, {name = "particles_demo", update = on_update, draw = on_draw}) {
		fmt.eprintln("Could not register particle system")
		return
	}
	if !rune.run(&game) {
		fmt.eprintln(rune.last_scene_error())
	}
}
