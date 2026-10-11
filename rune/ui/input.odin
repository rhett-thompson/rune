package ui

import "rune:input"
import rl "vendor:raylib"

// UI action names are ordinary rebindable Rune mappings. Missing actions are
// simply inactive. Pointer position/scroll come from raylib; synthetic Inputs
// may also be supplied directly to begin for headless tests or other devices.
read_input :: proc {read_mapped_input, read_context_input}

read_mapped_input :: proc(actions: ^input.Input) -> Inputs {
	return {
		pointer = rl.GetMousePosition(), pointer_down = rl.IsMouseButtonDown(.LEFT),
		scroll = rl.GetMouseWheelMoveV(),
		next = input.frame_action(actions, "ui_next").pressed,
		previous = input.frame_action(actions, "ui_previous").pressed,
		activate = input.frame_action(actions, "ui_accept").pressed,
		cancel = input.frame_action(actions, "ui_cancel").pressed,
		left = input.frame_action(actions, "ui_left").pressed,
		right = input.frame_action(actions, "ui_right").pressed,
	}
}

// Keep repeat state in the menu context so separate menus navigate independently.
// The one-argument overload remains available for callers managing their own nav.
read_context_input :: proc(ui: ^Context, actions: ^input.Input, dt: f32) -> Inputs {
	controls := read_mapped_input(actions)
	if ui == nil {return controls}
	if !rl.IsWindowFocused() {
		ui.nav.direction, ui.nav.remaining = .None, 0
		controls.blocked = true
		return controls
	}
	return merge_nav_inputs(controls, input.nav_update(&ui.nav, dt))
}

merge_nav_inputs :: proc(controls: Inputs, nav: input.Nav_Edges) -> Inputs {
	result := controls
	result.previous = result.previous || nav.up
	result.next = result.next || nav.down
	result.left = result.left || nav.left
	result.right = result.right || nav.right
	return result
}
