package main

import "core:fmt"
import "core:os"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

coin: ecs.Entity
knight: ecs.Entity
reverse: bool
knight_clip: int
capture_mode: bool
capture_frame: int

initialize :: proc(game: ^rune.Engine, world: ^ecs.World) {
	coin, _ = ecs.find_entity_by_id(world, "coin")
	knight, _ = ecs.find_entity_by_id(world, "knight")
	if capture_mode {
		knight_clip = 1
		ecs.play_sprite_animation(world, knight, "run")
	}
}

update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if input.pressed(rune.input_state(game), "change_direction") {
		reverse = !reverse
		ecs.play_sprite_animation(world, coin, "reverse" if reverse else "spin")
	}
	if input.pressed(rune.input_state(game), "next_knight_clip") {
		knight_clip = (knight_clip + 1) % 5
		ecs.play_sprite_animation(world, knight, knight_clip_name(knight_clip))
	}
}

knight_clip_name :: proc(index: int) -> string {
	switch index {
	case 0:
		return "idle"
	case 1:
		return "run"
	case 2:
		return "roll"
	case 3:
		return "hit"
	case 4:
		return "death"
	}
	return "idle"
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	rl.DrawText("JSON sprite-sheet animation", 24, 24, 28, rl.RAYWHITE)
	rl.DrawText("Tab: knight clip   Space: reverse coin", 24, 60, 18, rl.LIGHTGRAY)
	rl.DrawText("Knight clips: idle, run, roll, hit, death", 24, 88, 18, rl.LIGHTGRAY)
	if capture_mode && capture_frame == 30 {
		rl.TakeScreenshot("build/sprite_animation_2d_capture.png")
	}
	capture_frame += 1
	if capture_mode && capture_frame > 32 {rune.request_exit(game)}
}

main :: proc() {
	capture_mode = len(os.args) > 1 && os.args[1] == "--capture"
	game, ok := rune.init("examples/sprite_animation_2d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/sprite_animation_2d/project.json")
		return
	}
	defer rune.shutdown(&game)
	if !rune.register_system(
		&game,
		{
			name = "sprite_animation_2d",
			start = initialize,
			update = update,
			draw = draw,
			on_scene_reloaded = initialize,
		},
	) {
		fmt.eprintln("Could not register sprite-animation system")
		return
	}
	if !rune.run(&game) {fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())}
}
