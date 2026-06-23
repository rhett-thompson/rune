package main

import "core:fmt"
import "rune:input"

main :: proc() {
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

	fmt.println("Input mapping validation passed")
}
