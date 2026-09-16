package main

import "core:math"
import "core:testing"

@(test)
camera_height_transition_reverses_without_jumping :: proc(t: ^testing.T) {
	state: Camera_Height_Transition
	testing.expect(t, update_camera_height(&state, 1.6, 0.2, 0) == 1.6)
	testing.expect(t, math.abs(update_camera_height(&state, 0.8, 0.2, 0.1)-1.2) < 0.0001)
	testing.expect(t, math.abs(update_camera_height(&state, 1.6, 0.2, 0)-1.2) < 0.0001, "reversal starts at the visible height")
	testing.expect(t, math.abs(update_camera_height(&state, 1.6, 0.2, 0.1)-1.4) < 0.0001)
	testing.expect(t, update_camera_height(&state, 1.6, 0.2, 1) == 1.6, "exact endpoint")
	testing.expect(t, update_camera_height(&state, 1.6, 0.4, 0.1) == 1.6, "retuning a settled transition keeps its endpoint")
	testing.expect(t, update_camera_height(&state, 0.8, 0, 0) == 0.8, "disabled transition snaps")
}
