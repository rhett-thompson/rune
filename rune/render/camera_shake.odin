package render

import "core:math"

// Caller-owned transient angular shake. Keep offsets separate from the camera's
// persistent orientation so the effect cannot accumulate or change its aim.
Camera_Shake :: struct {
	time:      f64,
	amplitude: f32,
	duration:  f32,
}

// Amplitude is the maximum offset on either axis, in degrees; duration is in
// seconds. Retriggering replaces the previous effect. Nonpositive or nonfinite
// settings clear it, and the initial offset is zero.
camera_shake_start :: proc(state: ^Camera_Shake, amplitude, duration: f32) {
	if state == nil {return}
	state^ = {}
	if amplitude <= 0 || duration <= 0 ||
	   math.is_nan(amplitude) || math.is_inf(amplitude) ||
	   math.is_nan(duration) || math.is_inf(duration) {return}
	state.amplitude = amplitude
	state.duration = duration
}

// Advance in simulation seconds and return {yaw, pitch} offsets in degrees.
// A nonpositive timestep holds the current phase; a nonfinite timestep or
// invalid state clears the effect. Expiry returns exactly zero.
camera_shake_update :: proc(state: ^Camera_Shake, dt: f32) -> [2]f32 {
	if state == nil {return {}}
	if state.amplitude <= 0 || state.duration <= 0 || state.time < 0 ||
	   math.is_nan(state.amplitude) || math.is_inf(state.amplitude) ||
	   math.is_nan(state.duration) || math.is_inf(state.duration) ||
	   math.is_nan(state.time) || math.is_inf(state.time) ||
	   math.is_nan(dt) || math.is_inf(dt) {
		state^ = {}
		return {}
	}
	if dt > 0 {state.time += f64(dt)}
	if state.time >= f64(state.duration) {
		state^ = {}
		return {}
	}
	remaining := 1 - state.time / f64(state.duration)
	amplitude := f64(state.amplitude) * remaining * remaining
	return {
		f32(amplitude * math.sin(state.time * (2 * math.PI * 18))),
		f32(amplitude * math.sin(state.time * (2 * math.PI * 23))),
	}
}
