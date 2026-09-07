package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:tween"
import rl "vendor:raylib"

orb: ecs.Entity
motion: tween.Tween
easing_index: int

Orb_Start: [3]f32 : {140, 280, 0}
Orb_Target: [3]f32 : {820, 280, 0}
Color_Start :: tween.Color{0.25, 0.85, 1.0, 1.0}
Color_Target :: tween.Color{1.0, 0.30, 0.70, 0.35}

Easing_Option :: struct {
	name:   cstring,
	easing: tween.Ease,
}

easing_options := [6]Easing_Option {
	{"linear", tween.ease_linear},
	{"ease_in_quad", tween.ease_in_quad},
	{"ease_out_cubic", tween.ease_out_cubic},
	{"ease_in_out_sine", tween.ease_in_out_sine},
	{"ease_out_bounce", tween.ease_out_bounce},
	{"ease_out_elastic", tween.ease_out_elastic},
}

start_motion :: proc() {
	motion = tween.make(1.4, easing_options[easing_index].easing)
	motion.mode = .Ping_Pong
	motion.repeat = -1
}

initialize_tween :: proc(game: ^rune.Engine, world: ^ecs.World) {
	orb, _ = ecs.find_entity_by_id(world, "orb")
	start_motion()
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if input.pressed(rune.input_state(game), "cycle_easing") {
		easing_index = (easing_index + 1) % len(easing_options)
		start_motion()
	}
	tween.update(&motion, game.delta_time)

	transform, found := ecs.get_transform(world, orb)
	if !found { return }
	transform.position = tween.value_vec3(&motion, Orb_Start, Orb_Target)
	ecs.set_transform(world, orb, transform)
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	transform, found := ecs.get_transform(world, orb)
	if !found { return }

	color := tween.value_color(&motion, Color_Start, Color_Target)
	render_color := rl.Color{u8(color.r * 255), u8(color.g * 255), u8(color.b * 255), u8(color.a * 255)}
	rl.DrawCircleV({transform.position[0], transform.position[1]}, 38, render_color)
	rl.DrawText("Tweening and easing", 32, 28, 30, rl.RAYWHITE)
	rl.DrawText("Left-click to change easing", 32, 68, 18, rl.LIGHTGRAY)
	rl.DrawText(easing_options[easing_index].name, 32, 100, 22, rl.SKYBLUE)
}

main :: proc() {
	game, ok := rune.init("examples/tweening_2d/project.json")
	if !ok { fmt.eprintln("Could not load examples/tweening_2d/project.json"); return }
	defer rune.shutdown(&game)

	if !rune.register_system(
		&game,
		{
			name = "tweening",
			start = initialize_tween,
			update = on_update,
			draw = on_draw,
			on_scene_reloaded = initialize_tween,
		},
	) {
		fmt.eprintln("Could not register tweening system")
		return
	}
	if !rune.run(&game) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
