package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:tween"
import rl "vendor:raylib"

Transition_State :: enum { Idle, Fading_To_Black, Fading_From_Black }

Fade_Duration : f32 : 0.35

world: ecs.World
scene_index: int
transition_state: Transition_State
fade: tween.Tween

scene_paths := [2]string{
	"examples/scene_transition_2d/scenes/blue.scene.json",
	"examples/scene_transition_2d/scenes/pink.scene.json",
}

scene_names := [2]cstring{"Blue Scene", "Pink Scene"}
scene_colors := [2]rl.Color{rl.SKYBLUE, rl.PINK}

begin_transition :: proc() {
	transition_state = .Fading_To_Black
	fade = tween.make(Fade_Duration, tween.ease_in_out_quad)
}

load_next_scene :: proc(game: ^rune.Engine) -> bool {
	scene_index = (scene_index + 1) % len(scene_paths)
	next_world, loaded := rune.load_scene(game, scene_paths[scene_index])
	if !loaded { return false }
	world = next_world
	return true
}

on_update :: proc(game: ^rune.Engine) {
	if transition_state == .Idle && input.pressed(rune.input_state(game), "change_scene") {
		begin_transition()
	}

	if transition_state == .Idle || !tween.update(&fade, game.delta_time) { return }
	if transition_state == .Fading_To_Black {
		if !load_next_scene(game) {
			transition_state = .Idle
			return
		}
		transition_state = .Fading_From_Black
		fade = tween.make(Fade_Duration, tween.ease_in_out_quad)
		return
	}
	transition_state = .Idle
}

on_draw :: proc(game: ^rune.Engine) {
	orb, found := ecs.find_entity_by_id(&world, "scene_orb")
	if found {
		transform, has_transform := ecs.get_transform(&world, orb)
		if has_transform {
			rl.DrawCircleV({transform.position[0], transform.position[1]}, 96, scene_colors[scene_index])
		}
	}

	rl.DrawText("Runtime scene transition", 32, 28, 30, rl.RAYWHITE)
	rl.DrawText(scene_names[scene_index], 32, 72, 24, scene_colors[scene_index])
	rl.DrawText("Left-click to fade to black and load the next JSON scene.", 32, 108, 18, rl.LIGHTGRAY)

	if transition_state != .Idle {
		alpha := tween.value_f32(&fade, 0, 1)
		if transition_state == .Fading_From_Black { alpha = 1 - alpha }
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color{0, 0, 0, u8(alpha * 255)})
	}
}

main :: proc() {
	game, ok := rune.init("examples/scene_transition_2d/project.json")
	if !ok { fmt.eprintln("Could not load examples/scene_transition_2d/project.json"); return }
	defer rune.shutdown(&game)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, scene_paths[scene_index])
	if !scene_ok { fmt.eprintln("Could not load the initial transition scene"); return }
	rune.run(&game, on_update, on_draw)
}
