package main

import "core:fmt"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if console.is_open(rune.developer_console(game)) {return}
	controls := rune.input_state(game)
	burst, _ := ecs.find_entity_by_id(world, "burst")
	if input.pressed(controls, "burst") {ecs.emit_particles_2d(world, burst, 160)}
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
		for entity in ecs.query(world, ecs.ParticleEmitter2D) {ecs.clear_particles_2d(world, entity)}
	}
}

on_ui_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if console.is_open(rune.developer_console(game)) {return}
	if rl.IsKeyPressed(.F11) {rune.toggle_borderless(game)}
	if rl.IsKeyPressed(.ONE) {rune.set_resolution_2d(game,{policy=.fit,width=960,height=550})}
	if rl.IsKeyPressed(.TWO) {rune.set_resolution_2d(game,{policy=.stretch,width=960,height=550})}
	if rl.IsKeyPressed(.THREE) {rune.set_resolution_2d(game,{policy=.integer,width=960,height=550})}
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	rl.DrawText("PARTICLES / 2D", 40, 30, 30, {230, 238, 250, 255})
	rl.DrawText("SPACE burst     E toggle emitters     C clear     F3 gizmos", 40, 77, 18, {150, 164, 189, 255})
	rl.DrawText("1 fit   2 stretch   3 integer   F11 fullscreen",40,106,16,{123,138,165,255})
	rl.DrawText("JSON fountain", 123, 460, 20, {255, 204, 121, 255})
	rl.DrawText("Textured smoke", 391, 460, 20, {155, 194, 225, 255})
	rl.DrawText("Odin burst", 704, 460, 20, {140, 236, 210, 255})
	count := 0
	for entity in ecs.query(world, ecs.ParticleEmitter2D) {count += ecs.particle_count_2d(world, entity)}
	label := fmt.ctprintf("%d live particles | Edit scenes/main.scene.json to tune effects", count)
	rl.DrawText(label, 40, 507, 16, {123, 138, 165, 255})
}

main :: proc() {
	game, ok := rune.init("examples/particles_2d/project.json")
	if !ok {fmt.eprintln("Could not initialize particle example"); return}
	defer rune.shutdown(&game)
	if !rune.register_system(&game, {name = "particles_demo", ui_update = on_ui_update, update = on_update, draw = on_draw}) {return}
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
