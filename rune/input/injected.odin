package input

// Overrides persist until `input <action> clear` or engine shutdown. Edges are
// consumed by simulation updates, so pausing does not swallow a press/release.
Injected_Action :: struct {
	down: bool,
	previous: bool,
}

inject_action :: proc(input: ^Input, name: string, down: bool) -> bool {
	if !has_action(input, name) || input.arena == nil {return false}
	key := retain_string(input, name)
	state := input.injected[key]
	state.down = down
	input.injected[key] = state
	return true
}

clear_injected_action :: proc(input: ^Input, name: string) -> bool {
	if !has_action(input, name) {return false}
	delete_key(&input.injected, name)
	return true
}

apply_injected_actions :: proc(input: ^Input) {
	for name, injected in input.injected {
		input.actions[name] = Action_State {
			is_down = injected.down,
			pressed = injected.down && !injected.previous,
			released = !injected.down && injected.previous,
			strength = 1 if injected.down else 0,
		}
		next := injected
		next.previous = injected.down
		input.injected[name] = next
	}
}
