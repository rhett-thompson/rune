package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context
profile: ecs.Entity

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		ok: bool
		bridge, ok = r3d_bridge.init("examples/post_processing_3d", rl.GetRenderWidth(), rl.GetRenderHeight())
		if !ok {fmt.eprintln("Could not initialize r3d")}
	}
	profile, _ = ecs.find_entity_by_id(world, "post")
}

update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	value, found := ecs.get(world, profile, ecs.PostProcessing)
	if !found {return}
	previous := value
	controls := rune.input_state(game)
	if input.pressed(controls, "toggle") {value.enabled = !value.enabled}
	if input.pressed(controls, "bloom") {value.bloom.mode = .additive if value.bloom.mode == .disabled else .disabled}
	if input.pressed(controls, "ssao") {value.ssao.enabled = !value.ssao.enabled}
	if input.pressed(controls, "dof") {value.dof.enabled = !value.dof.enabled}
	if input.pressed(controls, "tonemap") {value.tonemap.mode = ecs.Post_Tonemap_Mode((int(value.tonemap.mode) + 1) % 5)}
	if input.pressed(controls, "exposure_up") {value.tonemap.exposure = min(8, value.tonemap.exposure + 0.1)}
	if input.pressed(controls, "exposure_down") {value.tonemap.exposure = max(0, value.tonemap.exposure - 0.1)}
	if value != previous {ecs.set(world, profile, value)}
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), {background_color = {9,13,22,255}})
	value, _ := ecs.get(world, profile, ecs.PostProcessing)
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), 140, {8,12,20,225})
	example_text.draw("POST PROCESSING / LIGHT GALLERY", 28, 20, 28, {225,238,255,255})
	example_text.draw(fmt.ctprintf("Profile: %s   |   Bloom: %s   |   SSAO: %s   |   DoF: %s   |   %v / exposure %.1fx",
		"ON" if value.enabled else "OFF", "ON" if value.bloom.mode != .disabled else "OFF",
		"ON" if value.ssao.enabled else "OFF", "ON" if value.dof.enabled else "OFF",
		value.tonemap.mode, value.tonemap.exposure), 28, 60, 18, {135,205,230,255})
	example_text.draw("SPACE Compare   B Bloom   O Occlusion   D Focus   T Tone map   UP/DOWN Exposure", 28, 91, 18, {185,196,213,255})
	example_text.draw("Left-drag to orbit. Edit scenes/main.scene.json and save to reload.", 28, rl.GetScreenHeight()-35, 18, {210,220,235,255})
}

shutdown :: proc(game: ^rune.Engine, world: ^ecs.World) {r3d_bridge.shutdown(&bridge)}

main :: proc() {
	game, ok := rune.init("examples/post_processing_3d/project.json")
	if !ok {fmt.eprintln("Could not load post-processing project"); return}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }
	if !rune.register_system(&game, {name = "post_processing", start = start, on_scene_reloaded = start,
		update = update, draw = draw, shutdown = shutdown}) {return}
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
