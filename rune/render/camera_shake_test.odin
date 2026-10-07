package render

import "core:testing"

@(test)
camera_shake_uses_elapsed_time_and_expires :: proc(t: ^testing.T) {
	coarse, fine: Camera_Shake
	camera_shake_start(&coarse, 0.8, 0.25)
	camera_shake_start(&fine, 0.8, 0.25)
	testing.expect(t, camera_shake_update(&coarse, 0) == [2]f32{}, "shake starts from zero")
	coarse_offset, fine_offset: [2]f32
	for _ in 0..<8 {coarse_offset = camera_shake_update(&coarse, 1.0 / 64)}
	for _ in 0..<32 {fine_offset = camera_shake_update(&fine, 1.0 / 256)}
	testing.expect(t, coarse_offset == fine_offset && coarse == fine, "equal elapsed time produces equal shake at different update rates")
	testing.expect(t, coarse_offset != [2]f32{}, "an active shake moves the view")
	before := coarse
	testing.expect(t, camera_shake_update(&coarse, 0) == coarse_offset && coarse == before, "pause freezes the phase")
	testing.expect(t, camera_shake_update(&coarse, -1) == coarse_offset && coarse == before, "negative time does not rewind")
	testing.expect(t, camera_shake_update(&coarse, 0.125) == [2]f32{} && coarse == Camera_Shake{}, "duration ends with exactly zero residual offset")
	testing.expect(t, camera_shake_update(&coarse, 1) == [2]f32{}, "expired shake remains zero")
}

@(test)
camera_shake_is_bounded_and_retriggerable :: proc(t: ^testing.T) {
	state: Camera_Shake
	camera_shake_start(&state, 0.8, 0.25)
	for _ in 0..<256 {
		offset := camera_shake_update(&state, 1.0 / 1024)
		testing.expect(t, abs(offset[0]) <= 0.8 && abs(offset[1]) <= 0.8, "both axes stay within the configured amplitude")
	}
	camera_shake_start(&state, 0.8, 0.25)
	_ = camera_shake_update(&state, 0.0625)
	camera_shake_start(&state, 0.2, 0.125)
	replay: Camera_Shake
	camera_shake_start(&replay, 0.2, 0.125)
	testing.expect(t, camera_shake_update(&state, 0.03125) == camera_shake_update(&replay, 0.03125) && state == replay, "retrigger replaces the previous effect without accumulating")
	camera_shake_start(&state, 0, 1)
	testing.expect(t, state == Camera_Shake{}, "zero amplitude disables shake")
	camera_shake_start(&state, 1, 0)
	testing.expect(t, state == Camera_Shake{}, "zero duration disables shake")
	nan := transmute(f32)u32(0x7fc00000)
	infinity := transmute(f32)u32(0x7f800000)
	camera_shake_start(&state, nan, 1)
	testing.expect(t, state == Camera_Shake{}, "invalid amplitude clears shake")
	camera_shake_start(&state, 1, infinity)
	testing.expect(t, state == Camera_Shake{}, "invalid duration clears shake")
	camera_shake_start(&state, 1, 1)
	testing.expect(t, camera_shake_update(&state, nan) == [2]f32{} && state == Camera_Shake{}, "invalid time cannot contaminate camera angles")
}
