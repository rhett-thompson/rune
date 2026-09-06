package input

// Capture gates action/is_down/pressed/released/strength/axis for the rest of this
// rendered frame. UI reads frame_action before or after capture. Raw raylib
// input remains available; gameplay using it must handle UI focus itself.
capture :: proc(input: ^Input) {input.captured = true}

// Read a UI action once during ui_update. Injected edges are consumed here,
// even when simulation is paused. Other injected gameplay actions remain queued
// for simulation as before. Use separate action names for UI and gameplay.
frame_action :: proc(input: ^Input, name: string) -> Action_State {
	if injected, found := input.injected[name]; found {
		result := Action_State{
			is_down = injected.down,
			pressed = injected.down && !injected.previous,
			released = !injected.down && injected.previous,
			strength = 1 if injected.down else 0,
		}
		injected.previous = injected.down
		input.injected[name] = injected
		return result
	}
	return input.actions[name]
}
