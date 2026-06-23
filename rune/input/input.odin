package input

import "core:encoding/json"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// Action_State is sampled once per frame. An action is active when any of its
// bindings are down; pressed and released are true if any binding transitions
// during that frame.
Action_State :: struct {
	is_down:  bool,
	pressed:  bool,
	released: bool,
	strength: f32,
}

Binding :: struct { type: string, key: string, button: string, gamepad: i32 }
Axis :: struct {
	type:     string,
	axis:     string,
	negative: string,
	positive: string,
	scale:    f32,
	invert:   bool,
}
Mappings :: struct { actions: map[string][]Binding, axes: map[string]Axis }
Input :: struct { mappings: Mappings, actions: map[string]Action_State, axes: map[string]f32 }

// load reads the declarative project input document. Invalid documents or
// unknown binding types are rejected so a project never silently loses input.
load :: proc(path: string) -> (Input, bool) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil { return {}, false }
	mappings: Mappings
	if json.unmarshal(data, &mappings) != nil || !validate_mappings(mappings) { return {}, false }
	return Input{mappings = mappings, actions = make(map[string]Action_State), axes = make(map[string]f32)}, true
}

validate_mappings :: proc(mappings: Mappings) -> bool {
	for _, bindings in mappings.actions {
		for binding in bindings {
			if binding.type == "keyboard" {
				if !key_from_name(binding.key).valid { return false }
			} else if binding.type == "mouse_button" {
				if !mouse_button_from_name(binding.button).valid { return false }
			} else if binding.type == "gamepad_button" {
				if !button_from_name(binding.button).valid || binding.gamepad < 0 { return false }
			} else { return false }
		}
	}
	for _, axis_data in mappings.axes {
		if axis_data.type == "mouse_delta" {
			if axis_data.axis != "x" && axis_data.axis != "y" { return false }
			continue
		}
		if len(axis_data.type) != 0 { return false }
		if _, found := mappings.actions[axis_data.negative]; !found { return false }
		if _, found := mappings.actions[axis_data.positive]; !found { return false }
	}
	return true
}

// update must be called once per frame after raylib polls input and before game
// systems query actions. Engine.run performs this automatically.
update :: proc(input: ^Input) {
	for action_name, bindings in input.mappings.actions {
		state: Action_State
		for binding in bindings {
			down, was_pressed, was_released := binding_state(binding)
			state.is_down ||= down
			state.pressed ||= was_pressed
			state.released ||= was_released
			if down { state.strength = 1 }
		}
		input.actions[action_name] = state
	}
	mouse_delta := rl.GetMouseDelta()
	for axis_name, axis_data in input.mappings.axes {
		if axis_data.type == "mouse_delta" {
			value := mouse_delta.x if axis_data.axis == "x" else mouse_delta.y
			scale := axis_data.scale
			if scale == 0 { scale = 1 }
			value *= scale
			if axis_data.invert { value = -value }
			input.axes[axis_name] = value
		} else {
			value := strength(input, axis_data.positive) - strength(input, axis_data.negative)
			if axis_data.invert { value = -value }
			input.axes[axis_name] = value
		}
	}
}

action :: proc(input: ^Input, name: string) -> Action_State {
	state := input.actions[name]
	state.is_down = binding_is_down(input, name)
	if state.is_down { state.strength = 1 } else { state.strength = 0 }
	return state
}
has_action :: proc(input: ^Input, name: string) -> bool { _, found := input.mappings.actions[name]; return found }
has_axis :: proc(input: ^Input, name: string) -> bool { _, found := input.mappings.axes[name]; return found }
is_down :: proc(input: ^Input, name: string) -> bool { return action(input, name).is_down }
pressed :: proc(input: ^Input, name: string) -> bool { return action(input, name).pressed }
released :: proc(input: ^Input, name: string) -> bool { return action(input, name).released }
strength :: proc(input: ^Input, name: string) -> f32 { return action(input, name).strength }
axis :: proc(input: ^Input, name: string) -> f32 {
	axis_data, found := input.mappings.axes[name]
	if !found { return 0 }
	if axis_data.type == "mouse_delta" { return input.axes[name] }
	value := strength(input, axis_data.positive) - strength(input, axis_data.negative)
	if axis_data.invert { value = -value }
	return value
}

binding_is_down :: proc(input: ^Input, action_name: string) -> bool {
	bindings, found := input.mappings.actions[action_name]
	if !found { return false }
	for binding in bindings {
		if binding.type == "keyboard" && rl.IsKeyDown(key_from_name(binding.key).key) { return true }
		if binding.type == "mouse_button" && rl.IsMouseButtonDown(mouse_button_from_name(binding.button).button) { return true }
		if binding.type == "gamepad_button" && rl.IsGamepadButtonDown(binding.gamepad, button_from_name(binding.button).button) { return true }
	}
	return false
}

binding_state :: proc(binding: Binding) -> (bool, bool, bool) {
	if binding.type == "keyboard" {
		key := key_from_name(binding.key).key
		return rl.IsKeyDown(key), rl.IsKeyPressed(key), rl.IsKeyReleased(key)
	}
	if binding.type == "mouse_button" {
		button := mouse_button_from_name(binding.button).button
		return rl.IsMouseButtonDown(button), rl.IsMouseButtonPressed(button), rl.IsMouseButtonReleased(button)
	}
	button := button_from_name(binding.button).button
	return rl.IsGamepadButtonDown(binding.gamepad, button), rl.IsGamepadButtonPressed(binding.gamepad, button), rl.IsGamepadButtonReleased(binding.gamepad, button)
}

Key_Result :: struct { key: rl.KeyboardKey, valid: bool }
key_from_name :: proc(name: string) -> Key_Result {
	upper := strings.to_upper(name, context.temp_allocator)
	if len(upper) == 1 {
		c := upper[0]
		if c >= 'A' && c <= 'Z' { return {rl.KeyboardKey(c), true} }
		if c >= '0' && c <= '9' { return {rl.KeyboardKey(c), true} }
	}
	switch upper {
	case "SPACE": return {.SPACE, true}
	case "LEFT": return {.LEFT, true}
	case "RIGHT": return {.RIGHT, true}
	case "UP": return {.UP, true}
	case "DOWN": return {.DOWN, true}
	case "ESCAPE", "ESC": return {.ESCAPE, true}
	case "ENTER": return {.ENTER, true}
	case "TAB": return {.TAB, true}
	case "BACKSPACE": return {.BACKSPACE, true}
	case "LEFT_SHIFT": return {.LEFT_SHIFT, true}
	case "RIGHT_SHIFT": return {.RIGHT_SHIFT, true}
	case "LEFT_CONTROL", "LEFT_CTRL": return {.LEFT_CONTROL, true}
	case "RIGHT_CONTROL", "RIGHT_CTRL": return {.RIGHT_CONTROL, true}
	}
	return {}
}

Button_Result :: struct { button: rl.GamepadButton, valid: bool }
button_from_name :: proc(name: string) -> Button_Result {
	upper := strings.to_upper(name, context.temp_allocator)
	switch upper {
	case "A": return {.RIGHT_FACE_DOWN, true}
	case "B": return {.RIGHT_FACE_RIGHT, true}
	case "X": return {.RIGHT_FACE_LEFT, true}
	case "Y": return {.RIGHT_FACE_UP, true}
	case "DPAD_UP": return {.LEFT_FACE_UP, true}
	case "DPAD_RIGHT": return {.LEFT_FACE_RIGHT, true}
	case "DPAD_DOWN": return {.LEFT_FACE_DOWN, true}
	case "DPAD_LEFT": return {.LEFT_FACE_LEFT, true}
	case "LEFT_BUMPER": return {.LEFT_TRIGGER_1, true}
	case "RIGHT_BUMPER": return {.RIGHT_TRIGGER_1, true}
	case "BACK": return {.MIDDLE_LEFT, true}
	case "START": return {.MIDDLE_RIGHT, true}
	case "LEFT_THUMB": return {.LEFT_THUMB, true}
	case "RIGHT_THUMB": return {.RIGHT_THUMB, true}
	}
	return {}
}

Mouse_Button_Result :: struct { button: rl.MouseButton, valid: bool }
mouse_button_from_name :: proc(name: string) -> Mouse_Button_Result {
	upper := strings.to_upper(name, context.temp_allocator)
	switch upper {
	case "LEFT": return {.LEFT, true}
	case "RIGHT": return {.RIGHT, true}
	case "MIDDLE": return {.MIDDLE, true}
	case "SIDE": return {.SIDE, true}
	case "EXTRA": return {.EXTRA, true}
	case "FORWARD": return {.FORWARD, true}
	case "BACK": return {.BACK, true}
	}
	return {}
}
