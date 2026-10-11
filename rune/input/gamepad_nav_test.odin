package input

import "core:math"
import "core:testing"

@(test)
nav_dominant_axis_and_neutral_edges :: proc(t: ^testing.T) {
	state: Nav_State
	testing.expect(t, nav_edges(&state, {0.59, 0.59}, 0.1) == Nav_Edges{})
	testing.expect(t, nav_edges(&state, {0.8, -0.7}, 0.1) == Nav_Edges{right=true}, "diagonal input selects only the dominant direction")
	testing.expect(t, nav_edges(&state, {0.8, -0.7}, 0.1) == Nav_Edges{})
	testing.expect(t, nav_edges(&state, {0.7, -0.8}, 0.1) == Nav_Edges{up=true})
	testing.expect(t, nav_edges(&state, {-0.8, 0.8}, 0.1) == Nav_Edges{left=true}, "equal axes consistently prefer horizontal")
	testing.expect(t, nav_edges(&state, {0, 0.8}, 0.1) == Nav_Edges{down=true})
	testing.expect(t, nav_edges(&state, {}, 5) == Nav_Edges{})
	testing.expect(t, state.direction == .None && state.remaining == 0)
	testing.expect(t, nav_edges(&state, {0, 0.8}, 0) == Nav_Edges{down=true}, "neutral re-arms an immediate edge")
}

@(test)
nav_delay_repeat_and_direction_restart :: proc(t: ^testing.T) {
	state: Nav_State
	stick := [2]f32{1, 0}
	testing.expect(t, nav_edges(&state, stick, 10).right, "first press never consumes its delay")
	testing.expect(t, nav_edges(&state, stick, 0.34) == Nav_Edges{})
	testing.expect(t, nav_edges(&state, stick, 0.02).right)
	testing.expect(t, nav_edges(&state, stick, 0.13) == Nav_Edges{})
	testing.expect(t, nav_edges(&state, stick, 0.02).right)
	testing.expect(t, nav_edges(&state, {-1, 0}, 0.13).left)
	testing.expect(t, nav_edges(&state, {-1, 0}, 0.15) == Nav_Edges{}, "a changed direction restarts the full initial delay")
	testing.expect(t, nav_edges(&state, {-1, 0}, 0.21).left)
	testing.expect(t, nav_edges(&state, {-1, 0}, 100).left, "a stalled frame emits one repeat")
	testing.expect(t, nav_edges(&state, {-1, 0}, 0.01) == Nav_Edges{}, "a stalled frame does not leave repeat debt")
}

@(test)
nav_invalid_time_disconnect_and_reset :: proc(t: ^testing.T) {
	state: Nav_State
	stick := [2]f32{1, 0}
	testing.expect(t, nav_edges(&state, stick, 0).right)
	for dt in ([4]f32{0, -1, math.nan_f32(), math.inf_f32(1)}) {
		testing.expect(t, nav_edges(&state, stick, dt) == Nav_Edges{})
	}
	testing.expect(t, state.remaining == 0.35, "invalid time does not advance repeat state")
	testing.expect(t, nav_edges(&state, {math.nan_f32(), 1}, 1) == Nav_Edges{})
	testing.expect(t, state.direction == .None)
	testing.expect(t, nav_edges(&state, stick, 0).right)
	testing.expect(t, nav_edges(&state, {1, math.inf_f32(1)}, 1) == Nav_Edges{})
	testing.expect(t, nav_edges(&state, stick, 0).right)
	testing.expect(t, nav_edges(&state, {}, 1) == Nav_Edges{}, "a disconnected pad sampled as zero clears its hold")
	testing.expect(t, nav_edges(&state, stick, 0).right)
	state = {}
	testing.expect(t, nav_edges(&state, stick, 0).right, "screen reset re-arms navigation")
	testing.expect(t, nav_edges(nil, stick, 1) == Nav_Edges{})
}

@(test)
nav_custom_and_invalid_settings :: proc(t: ^testing.T) {
	state := Nav_State{threshold=0.8, delay=0.5, repeat=0.25}
	testing.expect(t, nav_edges(&state, {0.7, 0}, 0.1) == Nav_Edges{})
	testing.expect(t, nav_edges(&state, {0.9, 0}, 0.1).right)
	testing.expect(t, nav_edges(&state, {0.9, 0}, 0.4) == Nav_Edges{})
	testing.expect(t, nav_edges(&state, {0.9, 0}, 0.11).right)
	testing.expect(t, nav_edges(&state, {0.9, 0}, 0.2) == Nav_Edges{})
	testing.expect(t, nav_edges(&state, {0.9, 0}, 0.06).right)
	state = {threshold=math.nan_f32(), delay=-1, repeat=math.inf_f32(1)}
	testing.expect(t, nav_edges(&state, {0.7, 0}, 0).right)
	testing.expect(t, state.remaining == 0.35)
	testing.expect(t, nav_edges(&state, {0.7, 0}, 0.36).right)
	testing.expect(t, state.remaining == 0.14)
}
