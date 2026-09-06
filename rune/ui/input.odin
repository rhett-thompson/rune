package ui

import "rune:input"
import rl "vendor:raylib"

// UI action names are ordinary rebindable Rune mappings. Missing actions are
// simply inactive. Pointer position/scroll come from raylib; synthetic Inputs
// may also be supplied directly to begin for headless tests or other devices.
read_input :: proc(actions: ^input.Input) -> Inputs {
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
