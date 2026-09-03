// Package tween provides small, code-driven interpolation helpers for gameplay
// presentation. Tween state is deliberately not serialized into scene JSON.
package tween

import "core:math"

Ease :: #type proc(t: f32) -> f32

Loop_Mode :: enum {
	None,
	Restart,
	Ping_Pong,
}

// Tween tracks normalized progress over a duration. repeat is the number of
// additional passes after the first; use -1 to repeat indefinitely.
Tween :: struct {
	duration, elapsed, delay:  f32,
	easing:                    Ease,
	mode:                      Loop_Mode,
	repeat, repeats_completed: int,
	direction:                 f32,
	running, completed:        bool,
}

// Color is a float RGBA value. It avoids coupling this utility package to a
// renderer while remaining easy to convert to a renderer-specific color type.
Color :: struct {
	r, g, b, a: f32,
}

make :: proc(duration: f32, easing: Ease = ease_linear) -> Tween {
	tween_duration := duration
	tween_easing := easing
	if tween_duration < 0 {tween_duration = 0}
	if tween_easing == nil {tween_easing = ease_linear}
	return Tween {
		duration = tween_duration,
		easing = tween_easing,
		mode = .None,
		direction = 1,
		running = true,
	}
}

// restart resets a tween to its initial, running state while retaining its
// duration, easing, and loop configuration.
restart :: proc(tween: ^Tween) {
	tween.elapsed = 0
	tween.repeats_completed = 0
	tween.direction = 1
	tween.running = true
	tween.completed = false
}

stop :: proc(tween: ^Tween) {tween.running = false}
is_running :: proc(tween: ^Tween) -> bool {return tween.running}
is_complete :: proc(tween: ^Tween) -> bool {return tween.completed}

// progress returns the current normalized linear progress, from 0 to 1.
progress :: proc(tween: ^Tween) -> f32 {
	if tween.duration <= 0 {
		if tween.completed {return 1}
		return 0
	}
	return clamp(tween.elapsed / tween.duration, 0, 1)
}

// eased_progress returns progress transformed through the tween's easing function.
eased_progress :: proc(tween: ^Tween) -> f32 {
	easing := tween.easing
	if easing == nil {easing = ease_linear}
	return easing(progress(tween))
}

// update advances a tween and returns true only on the frame it completes.
// Negative delta time is ignored.
update :: proc(tween: ^Tween, dt: f32) -> bool {
	remaining_dt := dt
	if !tween.running || remaining_dt <= 0 {return false}

	if tween.delay > 0 {
		tween.delay -= remaining_dt
		if tween.delay > 0 {return false}
		remaining_dt = -tween.delay
		tween.delay = 0
	}

	if tween.duration <= 0 {
		tween.elapsed = 0
		tween.running = false
		tween.completed = true
		return true
	}

	for remaining_dt > 0 {
		remaining: f32
		if tween.direction > 0 {
			remaining = tween.duration - tween.elapsed
		} else {
			remaining = tween.elapsed
		}
		if remaining_dt < remaining {
			tween.elapsed += remaining_dt * tween.direction
			return false
		}

		if tween.direction > 0 {
			tween.elapsed = tween.duration
		} else {
			tween.elapsed = 0
		}
		remaining_dt -= remaining
		if tween.mode == .None || (tween.repeat >= 0 && tween.repeats_completed >= tween.repeat) {
			tween.running = false
			tween.completed = true
			return true
		}

		tween.repeats_completed += 1
		switch tween.mode {
		case .Ping_Pong:
			tween.direction = -tween.direction
		case .None, .Restart:
			tween.elapsed = 0
			tween.direction = 1
		}
	}

	return false
}

value_f32 :: proc(tween: ^Tween, start, target: f32) -> f32 {return lerp_f32(
		start,
		target,
		eased_progress(tween),
	)}

value_vec2 :: proc(tween: ^Tween, start, target: [2]f32) -> [2]f32 {
	t := eased_progress(tween)
	return {lerp_f32(start[0], target[0], t), lerp_f32(start[1], target[1], t)}
}

value_vec3 :: proc(tween: ^Tween, start, target: [3]f32) -> [3]f32 {
	t := eased_progress(tween)
	return {
		lerp_f32(start[0], target[0], t),
		lerp_f32(start[1], target[1], t),
		lerp_f32(start[2], target[2], t),
	}
}

value_color :: proc(tween: ^Tween, start, target: Color) -> Color {
	t := eased_progress(tween)
	return Color {
		lerp_f32(start.r, target.r, t),
		lerp_f32(start.g, target.g, t),
		lerp_f32(start.b, target.b, t),
		lerp_f32(start.a, target.a, t),
	}
}

ease_linear :: proc(t: f32) -> f32 {return t}
ease_in_sine :: proc(t: f32) -> f32 {return 1 - f32(math.cos(f64(t) * math.PI / 2))}
ease_out_sine :: proc(t: f32) -> f32 {return f32(math.sin(f64(t) * math.PI / 2))}
ease_in_out_sine :: proc(t: f32) -> f32 {return f32(-(math.cos(math.PI * f64(t)) - 1) / 2)}
ease_in_quad :: proc(t: f32) -> f32 {return t * t}
ease_out_quad :: proc(t: f32) -> f32 {return 1 - (1 - t) * (1 - t)}
ease_in_out_quad :: proc(t: f32) -> f32 {if t < 0.5 {return 2 * t * t}; return(
		1 -
		f32(math.pow(f64(-2 * t + 2), 2)) / 2 \
	)}
ease_in_cubic :: proc(t: f32) -> f32 {return t * t * t}
ease_out_cubic :: proc(t: f32) -> f32 {return 1 - (1 - t) * (1 - t) * (1 - t)}
ease_in_out_cubic :: proc(t: f32) -> f32 {if t < 0.5 {return 4 * t * t * t}; return(
		1 -
		f32(math.pow(f64(-2 * t + 2), 3)) / 2 \
	)}
ease_in_quart :: proc(t: f32) -> f32 {return t * t * t * t}
ease_out_quart :: proc(t: f32) -> f32 {return 1 - f32(math.pow(f64(1 - t), 4))}
ease_in_out_quart :: proc(t: f32) -> f32 {if t < 0.5 {return 8 * t * t * t * t}; return(
		1 -
		f32(math.pow(f64(-2 * t + 2), 4)) / 2 \
	)}

ease_in_back :: proc(t: f32) -> f32 {c1 := f32(1.70158); c3 := c1 + 1; return(
		c3 * t * t * t -
		c1 * t * t \
	)}
ease_out_back :: proc(t: f32) -> f32 {c1 := f32(1.70158); c3 := c1 + 1; return(
		1 +
		c3 * f32(math.pow(f64(t - 1), 3)) +
		c1 * f32(math.pow(f64(t - 1), 2)) \
	)}
ease_in_out_back :: proc(t: f32) -> f32 {
	c1 := f32(1.70158)
	c2 := c1 * 1.525
	if t < 0.5 {
		p := 2 * t
		return p * p * ((c2 + 1) * p - c2) / 2
	}
	p := 2 * t - 2
	return (p * p * ((c2 + 1) * p + c2) + 2) / 2
}

ease_out_bounce :: proc(t: f32) -> f32 {
	n1, d1 := f32(7.5625), f32(2.75)
	if t < 1 / d1 {return n1 * t * t}
	if t < 2 / d1 {p := t - 1.5 / d1; return n1 * p * p + 0.75}
	if t < 2.5 / d1 {p := t - 2.25 / d1; return n1 * p * p + 0.9375}
	p := t - 2.625 / d1
	return n1 * p * p + 0.984375
}
ease_in_bounce :: proc(t: f32) -> f32 {return 1 - ease_out_bounce(1 - t)}
ease_in_out_bounce :: proc(t: f32) -> f32 {if t < 0.5 {return (1 - ease_out_bounce(1 - 2 * t)) / 2}
	return (1 + ease_out_bounce(2 * t - 1)) / 2}

ease_in_elastic :: proc(t: f32) -> f32 {
	if t == 0 || t == 1 {return t}
	c4 := 2 * math.PI / 3
	return -f32(math.pow(2, f64(10 * t - 10))) * f32(math.sin(f64(10 * t - 10) * c4))
}
ease_out_elastic :: proc(t: f32) -> f32 {
	if t == 0 || t == 1 {return t}
	c4 := 2 * math.PI / 3
	return f32(math.pow(2, f64(-10 * t))) * f32(math.sin(f64(10 * t - 0.75) * c4)) + 1
}
ease_in_out_elastic :: proc(t: f32) -> f32 {
	if t == 0 || t == 1 {return t}
	c5 := 2 * math.PI / 4.5
	if t < 0.5 {
		return -f32(math.pow(2, f64(20 * t - 10))) * f32(math.sin(f64(20 * t - 11.125) * c5)) / 2
	}
	return f32(math.pow(2, f64(-20 * t + 10))) * f32(math.sin(f64(20 * t - 11.125) * c5)) / 2 + 1
}

lerp_f32 :: proc(start, target, t: f32) -> f32 {return start + (target - start) * t}
clamp :: proc(value, minimum, maximum: f32) -> f32 {if value < minimum {return minimum}; if value >
	   maximum {return maximum}
	return value}
