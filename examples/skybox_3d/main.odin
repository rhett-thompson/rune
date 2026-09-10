package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if bridge.initialized {return}
	ok: bool
	bridge, ok = r3d_bridge.init("examples/skybox_3d", rl.GetRenderWidth(), rl.GetRenderHeight())
	if !ok {fmt.eprintln("Could not initialize r3d")}
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.draw_scene(&bridge, world, rune.asset_manager(game))
	sky, _ := ecs.find_entity_by_id(world, "sky")
	value, _ := ecs.get_skybox(world, sky)
	rl.DrawRectangle(20,20,730,114,{12,22,34,210})
	example_text.draw(fmt.ctprintf("SKYBOX / %v", value.mode), 36,32,26,rl.RAYWHITE)
	example_text.draw("Left-drag: orbit   TAB: sky mode   Sun: automatic 60-second cycle",36,72,18,rl.RAYWHITE)
	example_text.draw("Atmosphere: rotating sun and moon, with a dim blue night sky.",36,103,16,rl.RAYWHITE)
}

update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	controls := rune.input_state(game)
	sky, _ := ecs.find_entity_by_id(world, "sky")
	if input.pressed(controls,"sky_mode") {
		value, ok := ecs.get_skybox(world,sky)
		if ok {
			value.mode = .procedural if value.mode == .atmospheric else .atmospheric
			ecs.set_skybox(world,sky,value)
		}
	}
	sun, _ := ecs.find_entity_by_id(world,"sun")
	light, ok := ecs.get_directional_light(world,sun)
	if !ok {return}
	// Rotate in simulation time so pause/step controls also govern the sun.
	light.direction = rl.Vector3RotateByAxisAngle(
		light.direction, {-0.70710678,0,0.70710678}, 6 * rl.DEG2RAD * game.delta_time)
	ecs.set_directional_light(world,sun,light)
	moon, _ := ecs.find_entity_by_id(world,"moon")
	moon_light, moon_ok := ecs.get_directional_light(world,moon)
	if moon_ok {
		// Simple full-moon cycle; games can animate both lights independently.
		moon_light.direction = -light.direction
		ecs.set_directional_light(world,moon,moon_light)
	}
}

shutdown :: proc(game: ^rune.Engine, world: ^ecs.World) {r3d_bridge.shutdown(&bridge)}

main :: proc() {
	game, ok := rune.init("examples/skybox_3d/project.json")
	if !ok {fmt.eprintln("Could not load skybox project"); return}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }
	if !rune.register_system(&game, {name = "skybox", start = start, update = update, draw = draw, shutdown = shutdown}) {return}
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
