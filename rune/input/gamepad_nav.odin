package input

import "core:math"
import rl "vendor:raylib"

Nav_Direction :: enum { None, Up, Down, Left, Right }

// A zero-initialized state uses these defaults. Assign {} to reset navigation
// when closing a menu or changing screens.
Nav_State :: struct {
	threshold: f32, // default 0.6, valid range (0, 1]
	delay: f32,     // default 0.35 seconds
	repeat: f32,    // default 0.14 seconds
	direction: Nav_Direction,
	remaining: f32,
}

Nav_Edges :: struct { up, down, left, right: bool }

// Only the dominant axis navigates, so diagonal input advances one menu item.
// Direction changes emit immediately and restart the initial delay. Each
// sample emits at most one repeat, including frames with a large dt.
nav_edges :: proc(state: ^Nav_State, stick: [2]f32, dt: f32) -> Nav_Edges {
	if state == nil {return {}}
	threshold := nav_positive_or_default(state.threshold, 0.6)
	if threshold > 1 {threshold = 0.6}
	delay := nav_positive_or_default(state.delay, 0.35)
	repeat := nav_positive_or_default(state.repeat, 0.14)
	direction: Nav_Direction
	if !math.is_nan(stick.x) && !math.is_inf(stick.x) &&
	   !math.is_nan(stick.y) && !math.is_inf(stick.y) {
		if abs(stick.x) >= abs(stick.y) {
			if abs(stick.x) >= threshold {direction = .Left if stick.x < 0 else .Right}
		} else if abs(stick.y) >= threshold {
			direction = .Up if stick.y < 0 else .Down
		}
	}
	if direction == .None {
		state.direction = .None
		state.remaining = 0
		return {}
	}
	if direction != state.direction {
		state.direction = direction
		state.remaining = delay
		return nav_direction_edge(direction)
	}
	if math.is_nan(dt) || math.is_inf(dt) || dt <= 0 {return {}}
	state.remaining -= dt
	if state.remaining > 0 {return {}}
	state.remaining = repeat
	return nav_direction_edge(direction)
}

// Standalone polling supports Rune UI and programs without an engine. Pick the
// strongest left stick across raylib's first four slots, so idle controllers
// do not hide the controller currently navigating.
nav_update :: proc(state: ^Nav_State, dt: f32) -> Nav_Edges {
	stick: [2]f32
	strength: f32
	for pad: i32 = 0; pad < 4; pad += 1 {
		if !rl.IsGamepadAvailable(pad) {continue}
		candidate := [2]f32{rl.GetGamepadAxisMovement(pad, .LEFT_X), rl.GetGamepadAxisMovement(pad, .LEFT_Y)}
		if math.is_nan(candidate.x) || math.is_inf(candidate.x) ||
		   math.is_nan(candidate.y) || math.is_inf(candidate.y) {continue}
		candidate_strength := max(abs(candidate.x), abs(candidate.y))
		if candidate_strength > strength {stick = candidate; strength = candidate_strength}
	}
	return nav_edges(state, stick, dt)
}

@(private="file")
nav_positive_or_default :: proc(value, fallback: f32) -> f32 {
	if math.is_nan(value) || math.is_inf(value) || value <= 0 {return fallback}
	return value
}

@(private="file")
nav_direction_edge :: proc(direction: Nav_Direction) -> Nav_Edges {
	return {up = direction == .Up, down = direction == .Down,
	        left = direction == .Left, right = direction == .Right}
}
