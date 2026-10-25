package input

// Clear one-frame events before another simulation tick uses the same sampled
// input. Held actions, analog rates, capture, and pending injected edges remain.
// This does not change raw raylib input; call apply_injected_actions afterward
// when advancing injected simulation input. Ordinary frame sampling is unchanged.
clear_transients :: proc(input: ^Input) {
	if input == nil {return}
	for _, &state in input.actions {
		state.pressed = false
		state.released = false
	}
	for name, mapping in input.mappings.axes {
		if mapping.type == "mouse_delta" || mapping.type == "mouse_wheel" {input.axes[name] = 0}
	}
}
