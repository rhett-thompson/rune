package input

import "core:encoding/json"
import "core:mem"
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

Binding :: struct {
	type:    string,
	key:     string `json:"key,omitempty"`,
	button:  string `json:"button,omitempty"`,
	gamepad: i32 `json:"gamepad,omitempty"`,
}
Axis :: struct {
	type:     string `json:"type,omitempty"`,
	axis:     string `json:"axis,omitempty"`,
	negative: string `json:"negative,omitempty"`,
	positive: string `json:"positive,omitempty"`,
	scale:    f32 `json:"scale,omitempty"`,
	invert:   bool `json:"invert,omitempty"`,
}
Mappings :: struct {
	actions: map[string][]Binding,
	axes:    map[string]Axis,
}
Input :: struct {
	// UI capture lasts for one rendered frame and gates gameplay queries.
	captured:         bool,
	injected:         map[string]Injected_Action,
	mappings:         Mappings,
	actions:          map[string]Action_State,
	axes:             map[string]f32,
	path:             string,
	retained_strings: map[string]string,
	arena:            ^mem.Dynamic_Arena,
}

// load reads the declarative project input document. Invalid documents or
// unknown binding types are rejected so a project never silently loses input.
load :: proc(path: string) -> (Input, bool) {
	arena, _ := mem.new(mem.Dynamic_Arena)
	assert(arena != nil)
	mem.dynamic_arena_init(arena)
	allocator := mem.dynamic_arena_allocator(arena)
	result := Input {
		retained_strings = make(map[string]string, allocator),
		arena            = arena,
	}
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {destroy(&result); return {}, false}
	document: json.Value
	if json.unmarshal(data, &document, allocator = allocator) != nil {
		destroy(&result)
		return {}, false
	}
	object, object_ok := document.(json.Object)
	if !object_ok {destroy(&result); return {}, false}
	_, actions_found := object["actions"]
	_, axes_found := object["axes"]
	if !actions_found || !axes_found {destroy(&result); return {}, false}
	mappings: Mappings
	if json.unmarshal(data, &mappings, allocator = allocator) != nil ||
	   !validate_mappings(mappings) {
		destroy(&result)
		return {}, false
	}
	result.mappings = mappings
	result.actions = make(map[string]Action_State, allocator)
	result.injected = make(map[string]Injected_Action, allocator)
	result.axes = make(map[string]f32, allocator)
	result.path = retain_string(&result, path)
	return result, true
}

// destroy releases mappings, runtime state, retained paths, and JSON strings
// returned by load. Engine shutdown handles this for its owned Input value.
destroy :: proc(input: ^Input) {
	if input == nil || input.arena == nil {return}
	mem.dynamic_arena_destroy(input.arena)
	mem.free(input.arena)
	input^ = {}
}

retain_string :: proc(input: ^Input, value: string) -> string {
	if len(value) == 0 {return ""}
	if owned, found := input.retained_strings[value]; found {return owned}
	owned, _ := strings.clone(value, mem.dynamic_arena_allocator(input.arena))
	input.retained_strings[owned] = owned
	return owned
}

// save writes the current mappings to the same JSON file originally loaded.
// It emits canonical, pretty-printed JSON so a runtime rebind persists across
// the next launch.
save :: proc(input: ^Input) -> bool {
	if len(input.path) == 0 || !validate_mappings(input.mappings) {return false}
	data, marshal_error := json.marshal(
		input.mappings,
		json.Marshal_Options {
			pretty = true,
			use_spaces = true,
			spaces = 2,
			sort_maps_by_key = true,
		},
	)
	if marshal_error != nil {return false}
	defer delete(data)
	return os.write_entire_file(input.path, data) == nil
}

validate_mappings :: proc(mappings: Mappings) -> bool {
	for _, bindings in mappings.actions {
		if len(bindings) == 0 {return false}
		for binding in bindings {
			if binding.type == "keyboard" {
				if !key_from_name(binding.key).valid {return false}
			} else if binding.type == "mouse_button" {
				if !mouse_button_from_name(binding.button).valid {return false}
			} else if binding.type == "gamepad_button" {
				if !button_from_name(binding.button).valid || binding.gamepad < 0 {return false}
			} else {return false}
		}
	}
	for _, axis_data in mappings.axes {
		if axis_data.type == "mouse_delta" {
			if axis_data.axis != "x" && axis_data.axis != "y" {return false}
			continue
		}
		if axis_data.type == "mouse_wheel" {
			if len(axis_data.axis) != 0 {return false}
			continue
		}
		if len(axis_data.type) != 0 {return false}
		if _, found := mappings.actions[axis_data.negative]; !found {return false}
		if _, found := mappings.actions[axis_data.positive]; !found {return false}
	}
	return true
}

// update must be called once per frame after raylib polls input and before game
// systems query actions. Engine.run performs this automatically.
update :: proc(input: ^Input) {
	input.captured = false
	for action_name, bindings in input.mappings.actions {
		state: Action_State
		for binding in bindings {
			down, was_pressed, was_released := binding_state(binding)
			state.is_down ||= down
			state.pressed ||= was_pressed
			state.released ||= was_released
			if down {state.strength = 1}
		}
		input.actions[action_name] = state
	}
	mouse_delta := rl.GetMouseDelta()
	mouse_wheel := rl.GetMouseWheelMove()
	for axis_name, axis_data in input.mappings.axes {
		if axis_data.type == "mouse_delta" {
			value := mouse_delta.x if axis_data.axis == "x" else mouse_delta.y
			scale := axis_data.scale
			if scale == 0 {scale = 1}
			value *= scale
			if axis_data.invert {value = -value}
			input.axes[axis_name] = value
		} else if axis_data.type == "mouse_wheel" {
			value := mouse_wheel
			scale := axis_data.scale
			if scale == 0 {scale = 1}
			value *= scale
			if axis_data.invert {value = -value}
			input.axes[axis_name] = value
		} else {
			value := strength(input, axis_data.positive) - strength(input, axis_data.negative)
			if axis_data.invert {value = -value}
			input.axes[axis_name] = value
		}
	}
}

action :: proc(input: ^Input, name: string) -> Action_State {
	if input.captured {return {}}
	// update samples every binding once per frame. Queries must only read that
	// cached state so systems do not rescan bindings or allocate uppercase names.
	return input.actions[name]
}
has_action :: proc(input: ^Input, name: string) -> bool {_, found := input.mappings.actions[name]
	return found}
has_axis :: proc(input: ^Input, name: string) -> bool {_, found := input.mappings.axes[name]
	return found}

// rebind_keyboard replaces an action's first keyboard binding. Existing mouse
// and gamepad bindings remain available. The action must already define a
// keyboard binding in its input JSON.
//
// The change is applied to subsequent input updates; callers normally invoke
// this from an update callback after testing a separate action.
rebind_keyboard :: proc(input: ^Input, action_name, key: string) -> bool {
	if !has_action(input, action_name) || !key_from_name(key).valid {return false}

	bindings := input.mappings.actions[action_name]
	for binding_index in 0 ..< len(bindings) {
		if bindings[binding_index].type == "keyboard" {
			bindings[binding_index] = Binding {
				type = "keyboard",
				key  = retain_string(input, key),
			}
			input.mappings.actions[action_name] = bindings
			return true
		}
	}

	return false
}

// keyboard_binding returns the first configured keyboard binding for an action.
keyboard_binding :: proc(input: ^Input, action_name: string) -> (string, bool) {
	bindings, found := input.mappings.actions[action_name]
	if !found {return "", false}
	for binding in bindings {
		if binding.type == "keyboard" {return binding.key, true}
	}
	return "", false
}

is_down :: proc(input: ^Input, name: string) -> bool {return action(input, name).is_down}
pressed :: proc(input: ^Input, name: string) -> bool {return action(input, name).pressed}
released :: proc(input: ^Input, name: string) -> bool {return action(input, name).released}
strength :: proc(input: ^Input, name: string) -> f32 {return action(input, name).strength}
axis :: proc(input: ^Input, name: string) -> f32 {
	if input.captured {return 0}
	axis_data, found := input.mappings.axes[name]
	if !found {return 0}
	if len(axis_data.type) != 0 {return input.axes[name]}
	value := strength(input, axis_data.positive) - strength(input, axis_data.negative)
	if axis_data.invert {value = -value}
	return value
}

binding_state :: proc(binding: Binding) -> (bool, bool, bool) {
	if binding.type == "keyboard" {
		key := key_from_name(binding.key).key
		return rl.IsKeyDown(key), rl.IsKeyPressed(key), rl.IsKeyReleased(key)
	}
	if binding.type == "mouse_button" {
		button := mouse_button_from_name(binding.button).button
		return rl.IsMouseButtonDown(
			button,
		), rl.IsMouseButtonPressed(button), rl.IsMouseButtonReleased(button)
	}
	button := button_from_name(binding.button).button
	return rl.IsGamepadButtonDown(
		binding.gamepad,
		button,
	), rl.IsGamepadButtonPressed(binding.gamepad, button), rl.IsGamepadButtonReleased(binding.gamepad, button)
}

Key_Result :: struct {
	key:   rl.KeyboardKey,
	valid: bool,
}
key_from_name :: proc(name: string) -> Key_Result {
	buffer: [32]u8
	upper := uppercase_binding_name(name, buffer[:])
	if len(upper) == 1 {
		c := upper[0]
		if c >= 'A' && c <= 'Z' {return {rl.KeyboardKey(c), true}}
		if c >= '0' && c <= '9' {return {rl.KeyboardKey(c), true}}
	}
	switch upper {
	case "SPACE":
		return {.SPACE, true}
	case "LEFT":
		return {.LEFT, true}
	case "RIGHT":
		return {.RIGHT, true}
	case "UP":
		return {.UP, true}
	case "DOWN":
		return {.DOWN, true}
	case "ESCAPE", "ESC":
		return {.ESCAPE, true}
	case "ENTER":
		return {.ENTER, true}
	case "TAB":
		return {.TAB, true}
	case "BACKSPACE":
		return {.BACKSPACE, true}
	case "LEFT_SHIFT":
		return {.LEFT_SHIFT, true}
	case "RIGHT_SHIFT":
		return {.RIGHT_SHIFT, true}
	case "LEFT_CONTROL", "LEFT_CTRL":
		return {.LEFT_CONTROL, true}
	case "RIGHT_CONTROL", "RIGHT_CTRL":
		return {.RIGHT_CONTROL, true}
	}
	return {}
}

Button_Result :: struct {
	button: rl.GamepadButton,
	valid:  bool,
}
button_from_name :: proc(name: string) -> Button_Result {
	buffer: [32]u8
	upper := uppercase_binding_name(name, buffer[:])
	switch upper {
	case "A":
		return {.RIGHT_FACE_DOWN, true}
	case "B":
		return {.RIGHT_FACE_RIGHT, true}
	case "X":
		return {.RIGHT_FACE_LEFT, true}
	case "Y":
		return {.RIGHT_FACE_UP, true}
	case "DPAD_UP":
		return {.LEFT_FACE_UP, true}
	case "DPAD_RIGHT":
		return {.LEFT_FACE_RIGHT, true}
	case "DPAD_DOWN":
		return {.LEFT_FACE_DOWN, true}
	case "DPAD_LEFT":
		return {.LEFT_FACE_LEFT, true}
	case "LEFT_BUMPER":
		return {.LEFT_TRIGGER_1, true}
	case "RIGHT_BUMPER":
		return {.RIGHT_TRIGGER_1, true}
	case "BACK":
		return {.MIDDLE_LEFT, true}
	case "START":
		return {.MIDDLE_RIGHT, true}
	case "LEFT_THUMB":
		return {.LEFT_THUMB, true}
	case "RIGHT_THUMB":
		return {.RIGHT_THUMB, true}
	}
	return {}
}

Mouse_Button_Result :: struct {
	button: rl.MouseButton,
	valid:  bool,
}
mouse_button_from_name :: proc(name: string) -> Mouse_Button_Result {
	buffer: [32]u8
	upper := uppercase_binding_name(name, buffer[:])
	switch upper {
	case "LEFT":
		return {.LEFT, true}
	case "RIGHT":
		return {.RIGHT, true}
	case "MIDDLE":
		return {.MIDDLE, true}
	case "SIDE":
		return {.SIDE, true}
	case "EXTRA":
		return {.EXTRA, true}
	case "FORWARD":
		return {.FORWARD, true}
	case "BACK":
		return {.BACK, true}
	}
	return {}
}

// Supported binding names are short ASCII tokens. Normalize into caller-owned
// stack storage on the sampling path, preserving Unicode behavior as a fallback.
uppercase_binding_name :: proc(name: string, buffer: []u8) -> string {
	if len(name) > len(buffer) {return strings.to_upper(name, context.temp_allocator)}
	for character, index in transmute([]u8)name {
		if character >= 128 {return strings.to_upper(name, context.temp_allocator)}
		buffer[index] = character - ('a' - 'A') if character >= 'a' && character <= 'z' else character
	}
	return string(buffer[:len(name)])
}
