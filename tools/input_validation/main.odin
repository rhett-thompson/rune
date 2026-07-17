package main

import "core:fmt"
import "core:os"
import "rune:input"

restore_file :: proc(path: string, data: []byte) {
	assert(os.write_entire_file(path, data) == nil)
}

main :: proc() {
	invalid_input_path := "build/input_validation_invalid.input.json"
	defer os.remove(invalid_input_path)
	missing_axes_json: string = `{"actions":{}}`
	assert(os.write_entire_file(invalid_input_path, missing_axes_json) == nil)
	_, missing_axes_loaded := input.load(invalid_input_path)
	assert(!missing_axes_loaded)
	empty_action_json: string = `{"actions":{"jump":[]},"axes":{}}`
	assert(os.write_entire_file(invalid_input_path, empty_action_json) == nil)
	_, empty_action_loaded := input.load(invalid_input_path)
	assert(!empty_action_loaded)

	rebinding_path := "examples/runtime_rebinding/input/default.input.json"
	original_rebinding, read_error := os.read_entire_file(rebinding_path, context.allocator)
	assert(read_error == nil)
	defer delete(original_rebinding)
	defer restore_file(rebinding_path, original_rebinding)
	camera_input, camera_loaded := input.load("examples/camera_switching/input/default.input.json")
	assert(camera_loaded)
	assert(input.has_action(&camera_input, "camera_one"))
	assert(input.has_action(&camera_input, "camera_two"))
	assert(input.has_action(&camera_input, "camera_three"))

	mover_input, mover_loaded := input.load("examples/custom_mover/input/default.input.json")
	assert(mover_loaded)
	assert(input.has_action(&mover_input, "move_left"))
	assert(input.has_axis(&mover_input, "move_x"))

	third_person_input, third_person_loaded := input.load("examples/third_person_3d/input/default.input.json")
	assert(third_person_loaded)
	assert(input.has_axis(&third_person_input, "zoom"))

	rebinding_input, rebinding_loaded := input.load(rebinding_path)
	assert(rebinding_loaded)
	assert(input.rebind_keyboard(&rebinding_input, "move_left", "LEFT"))
	assert(input.rebind_keyboard(&rebinding_input, "move_right", "RIGHT"))
	assert(!input.rebind_keyboard(&rebinding_input, "missing", "A"))
	assert(!input.rebind_keyboard(&rebinding_input, "move_left", "NOT_A_KEY"))
	assert(input.rebind_keyboard(&rebinding_input, "move_left", "A"))
	assert(input.rebind_keyboard(&rebinding_input, "move_right", "D"))
	assert(input.save(&rebinding_input))
	saved_rebinding_input, saved_rebinding_loaded := input.load(rebinding_path)
	assert(saved_rebinding_loaded)
	left_key, left_key_found := input.keyboard_binding(&saved_rebinding_input, "move_left")
	right_key, right_key_found := input.keyboard_binding(&saved_rebinding_input, "move_right")
	assert(left_key_found && left_key == "A")
	assert(right_key_found && right_key == "D")

	fmt.println("Input mapping validation passed")
}
