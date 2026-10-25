package input

import "core:testing"

@(test)
clear_transients_preserves_held_input_and_rate_axes :: proc(t: ^testing.T) {
	controls: Input
	controls.actions = make(map[string]Action_State)
	defer delete(controls.actions)
	controls.axes = make(map[string]f32)
	defer delete(controls.axes)
	controls.mappings.axes = make(map[string]Axis)
	defer delete(controls.mappings.axes)
	controls.captured = true
	controls.actions["held"] = {is_down = true, pressed = true, strength = 0.75}
	controls.actions["released"] = {released = true}
	controls.mappings.axes["look_x"] = {type = "mouse_delta", axis = "x", scale = 2}
	controls.mappings.axes["scroll"] = {type = "mouse_wheel", axis = "y"}
	controls.mappings.axes["move"] = {negative = "left", positive = "right"}
	controls.mappings.axes["stick"] = {type = "gamepad_axis", axis = "LEFT_X"}
	controls.axes["look_x"] = 12
	controls.axes["scroll"] = -2
	controls.axes["move"] = 1
	controls.axes["stick"] = 0.5
	for _ in 0..<2 {
		clear_transients(&controls)
		held, released := controls.actions["held"], controls.actions["released"]
		testing.expect(t, held.is_down && held.strength == 0.75 && !held.pressed && !held.released)
		testing.expect(t, !released.is_down && !released.pressed && !released.released && released.strength == 0)
		testing.expect(t, controls.axes["look_x"] == 0 && controls.axes["scroll"] == 0)
		testing.expect(t, controls.axes["move"] == 1 && controls.axes["stick"] == 0.5)
		testing.expect(t, controls.captured && controls.mappings.axes["look_x"].scale == 2)
	}
	empty: Input
	clear_transients(&empty)
	clear_transients(nil)
}

@(test)
clear_transients_leaves_pending_injected_edges_for_the_next_tick :: proc(t: ^testing.T) {
	controls: Input
	controls.actions = make(map[string]Action_State)
	defer delete(controls.actions)
	controls.injected = make(map[string]Injected_Action)
	defer delete(controls.injected)
	controls.injected["move"] = {down = true}
	clear_transients(&controls)
	testing.expect(t, controls.injected["move"].down && !controls.injected["move"].previous)
	apply_injected_actions(&controls)
	testing.expect(t, controls.actions["move"].pressed && controls.actions["move"].is_down)
	clear_transients(&controls)
	apply_injected_actions(&controls)
	testing.expect(t, !controls.actions["move"].pressed && controls.actions["move"].is_down)
	controls.injected["move"] = {down = false, previous = true}
	clear_transients(&controls)
	testing.expect(t, controls.injected["move"].previous)
	apply_injected_actions(&controls)
	testing.expect(t, controls.actions["move"].released && !controls.actions["move"].is_down)
	clear_transients(&controls)
	apply_injected_actions(&controls)
	testing.expect(t, !controls.actions["move"].released && !controls.actions["move"].is_down)
}
