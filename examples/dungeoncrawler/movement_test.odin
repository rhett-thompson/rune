package main

import "core:math"
import "core:testing"

@(test)
dungeon_analog_movement_preserves_partial_speed_and_caps_diagonals :: proc(t: ^testing.T) {
	testing.expect(t, dungeon_move_axes({0.1, 0}) == [2]f32{0.1, 0}, "small stick deflection stays one tenth of walking speed")
	testing.expect(t, dungeon_move_axes({0.3, -0.4}) == [2]f32{0.3, -0.4}, "a partial diagonal retains its analog magnitude")
	testing.expect(t, dungeon_move_axes({}) == [2]f32{}, "neutral movement stays zero")
	diagonal := dungeon_move_axes({1, 1})
	length := math.sqrt(diagonal[0]*diagonal[0]+diagonal[1]*diagonal[1])
	testing.expect(t, abs(length-1) < 0.00001, "keyboard diagonals cannot exceed full walking speed")
	testing.expect(t, abs(diagonal[0]-diagonal[1]) < 0.00001)
}
