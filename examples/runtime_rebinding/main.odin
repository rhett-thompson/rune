package main

import "core:fmt"
import rune "rune:core"
import "rune:input"
import rl "vendor:raylib"

player_x: f32 = 480
using_arrow_keys := false
last_save_succeeded := true

on_update :: proc(game: ^rune.Engine) {
	controls := rune.input_state(game)
	if input.pressed(controls, "toggle_bindings") {
		if using_arrow_keys {
			left_rebound := input.rebind_keyboard(controls, "move_left", "A")
			right_rebound := input.rebind_keyboard(controls, "move_right", "D")
			if left_rebound && right_rebound {
				using_arrow_keys = false
				last_save_succeeded = input.save(controls)
			}
		} else {
			left_rebound := input.rebind_keyboard(controls, "move_left", "LEFT")
			right_rebound := input.rebind_keyboard(controls, "move_right", "RIGHT")
			if left_rebound && right_rebound {
				using_arrow_keys = true
				last_save_succeeded = input.save(controls)
			}
		}
	}

	direction := input.axis(controls, "move_x")
	player_x += direction * 360 * game.delta_time
	if player_x < 28 { player_x = 28 }
	if player_x > 932 { player_x = 932 }
}

on_draw :: proc(game: ^rune.Engine) {
	rl.DrawText("Runtime Key Rebinding", 32, 32, 32, rl.DARKGRAY)
	rl.DrawText("Press R to switch the movement bindings.", 32, 80, 20, rl.GRAY)
	if using_arrow_keys {
		rl.DrawText("Current movement keys: Left / Right", 32, 112, 22, rl.MAROON)
	} else {
		rl.DrawText("Current movement keys: A / D", 32, 112, 22, rl.MAROON)
	}
	rl.DrawRectangle(28, 190, 904, 4, rl.LIGHTGRAY)
	rl.DrawCircle(i32(player_x), 192, 28, rl.SKYBLUE)
	if last_save_succeeded {
		rl.DrawText("Saved to input/default.input.json", 32, 250, 18, rl.DARKGREEN)
	} else {
		rl.DrawText("Could not save input/default.input.json", 32, 250, 18, rl.MAROON)
	}
}

main :: proc() {
	game, ok := rune.init("examples/runtime_rebinding/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/runtime_rebinding/project.json")
		return
	}
	defer rune.shutdown(&game)

	left_binding, found := input.keyboard_binding(rune.input_state(&game), "move_left")
	using_arrow_keys = found && left_binding == "LEFT"
	rune.run(&game, on_update, on_draw)
}
