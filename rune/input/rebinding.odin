package input

import "core:mem"
import "core:reflect"
import rl "vendor:raylib"

// Names borrow permanent literals/type metadata, never scratch storage. Empty
// names indicate unsupported/unknown native codes. Digits use mapping tokens
// "0".."9" rather than raylib's ZERO..NINE enum names.
keyboard_key_name :: proc(key: rl.KeyboardKey) -> string {
	if key==.KEY_NULL {return ""}
	if key>=.ZERO && key<=.NINE {
		digits := "0123456789"
		index:=int(key)-int(rl.KeyboardKey.ZERO)
		return digits[index:index+1]
	}
	return reflect.enum_string(key)
}

mouse_button_name :: proc(button: rl.MouseButton) -> string {
	return reflect.enum_string(button)
}

gamepad_button_name :: proc(button: rl.GamepadButton) -> string {
	switch button {
	case .RIGHT_FACE_DOWN: return "A"
	case .RIGHT_FACE_RIGHT: return "B"
	case .RIGHT_FACE_LEFT: return "X"
	case .RIGHT_FACE_UP: return "Y"
	case .LEFT_FACE_UP: return "DPAD_UP"
	case .LEFT_FACE_RIGHT: return "DPAD_RIGHT"
	case .LEFT_FACE_DOWN: return "DPAD_DOWN"
	case .LEFT_FACE_LEFT: return "DPAD_LEFT"
	case .LEFT_TRIGGER_1: return "LEFT_BUMPER"
	case .RIGHT_TRIGGER_1: return "RIGHT_BUMPER"
	case .LEFT_TRIGGER_2: return "LEFT_TRIGGER"
	case .RIGHT_TRIGGER_2: return "RIGHT_TRIGGER"
	case .MIDDLE_LEFT: return "BACK"
	case .MIDDLE_RIGHT: return "START"
	case .MIDDLE: return "GUIDE"
	case .LEFT_THUMB: return "LEFT_THUMB"
	case .RIGHT_THUMB: return "RIGHT_THUMB"
	case .UNKNOWN: return ""
	}
	return ""
}

// Canonical names borrow permanent strings. Only variant-specific fields are
// retained; irrelevant key/button/gamepad data does not affect equality.
canonical_binding :: proc(binding: Binding) -> (Binding, bool) {
	switch binding.type {
	case "keyboard":
		key:=key_from_name(binding.key)
		if !key.valid {return {},false}
		return {type="keyboard",key=keyboard_key_name(key.key)},true
	case "mouse_button":
		button:=mouse_button_from_name(binding.button)
		if !button.valid {return {},false}
		return {type="mouse_button",button=mouse_button_name(button.button)},true
	case "gamepad_button":
		button:=button_from_name(binding.button)
		if !button.valid || binding.gamepad<0 {return {},false}
		return {type="gamepad_button",button=gamepad_button_name(button.button),gamepad=binding.gamepad},true
	}
	return {},false
}

binding_equal :: proc(a, b: Binding) -> bool {
	left,left_valid:=canonical_binding(a)
	right,right_valid:=canonical_binding(b)
	return left_valid && right_valid && left==right
}

// Configuration clone with independent ownership. Paths, schema, all action
// slots and every axis field are copied exactly. Runtime samples/injections are
// deliberately fresh; callers must destroy the returned Input when finished.
clone :: proc(source: ^Input) -> (Input, bool) {
	if source==nil || !validate_mappings(source.mappings) {return {},false}
	arena,_:=mem.new(mem.Dynamic_Arena)
	if arena==nil {return {},false}
	mem.dynamic_arena_init(arena)
	a:=mem.dynamic_arena_allocator(arena)
	result:=Input{
		arena=arena,retained_strings=make(map[string]string,a),
		mappings={actions=make(map[string][]Binding,a),axes=make(map[string]Axis,a)},
		actions=make(map[string]Action_State,a),injected=make(map[string]Injected_Action,a),axes=make(map[string]f32,a),
	}
	result.path=retain_string(&result,source.path)
	result.schema=retain_string(&result,source.schema); result.has_schema=source.has_schema
	for name,bindings in source.mappings.actions {
		owned:=make([]Binding,len(bindings),a)
		for binding,index in bindings {
			owned[index]=binding
			owned[index].type=retain_string(&result,binding.type)
			owned[index].key=retain_string(&result,binding.key)
			owned[index].button=retain_string(&result,binding.button)
		}
		result.mappings.actions[retain_string(&result,name)]=owned
	}
	for name,axis in source.mappings.axes {
		owned:=axis
		owned.type=retain_string(&result,axis.type); owned.axis=retain_string(&result,axis.axis)
		owned.negative=retain_string(&result,axis.negative); owned.positive=retain_string(&result,axis.positive)
		result.mappings.axes[retain_string(&result,name)]=owned
	}
	return result,true
}

// Replace any existing action slot. This changes only configuration; conflict
// policy, draft UI and persistence belong to the caller. Stored strings belong
// to the input arena, so caller strings may be temporary.
rebind :: proc(controls: ^Input, action_name: string, slot: int, binding: Binding) -> bool {
	if controls==nil || controls.arena==nil || !validate_mappings(controls.mappings) {return false}
	bindings,found:=controls.mappings.actions[action_name]
	if !found || slot<0 || slot>=len(bindings) {return false}
	canonical,valid:=canonical_binding(binding)
	if !valid {return false}
	canonical.type=retain_string(controls,canonical.type)
	canonical.key=retain_string(controls,canonical.key)
	canonical.button=retain_string(controls,canonical.button)
	bindings[slot]=canonical
	return true
}

// Consume an independently owned, already prepared configuration without
// allocating. Target's address stays stable; source is zeroed after success.
// Runtime state is reset and gameplay queries are captured for this frame.
// Validate before saving when using this as a post-persistence commit step.
move_configuration :: proc(target, source: ^Input) -> bool {
	if target==nil || source==nil || target==source || source.arena==nil ||
		(target.arena!=nil && target.arena==source.arena) || !validate_mappings(source.mappings) {return false}
	clear(&source.actions); clear(&source.injected); clear(&source.axes)
	source.captured=true
	destroy(target)
	target^=source^
	source^={}
	return true
}

// Clone before replacing so invalid sources leave the target entirely intact.
// Source remains independently usable, including when target==source.
replace_configuration :: proc(target, source: ^Input) -> bool {
	if target==nil || (source!=nil && target!=source && target.arena!=nil && target.arena==source.arena) {return false}
	prepared,valid:=clone(source)
	if !valid {return false}
	defer destroy(&prepared)
	return move_configuration(target,&prepared)
}
