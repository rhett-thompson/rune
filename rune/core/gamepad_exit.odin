package core

import "core:math"
import rl "vendor:raylib"

Gamepad_Exit_Hold_Seconds: f32 : 1

// Each controller must finish its own uninterrupted hold. Combining holds
// across controllers would let a device handoff unexpectedly close a game.
Gamepad_Exit_State :: struct {
	elapsed: [4]f32,
	fired: [4]bool,
}

// START remains an ordinary bindable button on a tap. This engine default
// closes the active loop only after a one-second hold, even without mappings.
set_gamepad_exit :: proc(engine: ^Engine, enabled: bool) {
	if engine == nil {return}
	engine.gamepad_exit_disabled = !enabled
	engine.gamepad_exit_state = {}
}

gamepad_exit_tick :: proc(state: ^Gamepad_Exit_State, held: [4]bool, dt: f32, focused, enabled: bool) -> bool {
	if state == nil {return false}
	if !focused || !enabled {state^ = {}; return false}
	valid_dt := dt > 0 && !math.is_nan(dt) && !math.is_inf(dt)
	exit: bool
	for down, pad in held {
		if !down {
			state.elapsed[pad] = 0
			state.fired[pad] = false
			continue
		}
		if state.fired[pad] || !valid_dt {continue}
		state.elapsed[pad] = min(Gamepad_Exit_Hold_Seconds, state.elapsed[pad] + dt)
		if state.elapsed[pad] >= Gamepad_Exit_Hold_Seconds {
			state.fired[pad] = true
			exit = true
		}
	}
	return exit
}

@(private)
update_gamepad_exit :: proc(engine: ^Engine, dt: f32) {
	focused := rl.IsWindowFocused()
	enabled := !engine.gamepad_exit_disabled
	held: [4]bool
	if focused && enabled {
		for pad: i32 = 0; pad < 4; pad += 1 {
			held[pad] = rl.IsGamepadAvailable(pad) && rl.IsGamepadButtonDown(pad, .MIDDLE_RIGHT)
		}
	}
	if gamepad_exit_tick(&engine.gamepad_exit_state, held, dt, focused, enabled) {
		request_exit(engine)
	}
}
