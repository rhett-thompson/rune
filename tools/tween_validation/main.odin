package main

import "core:fmt"
import "rune:tween"

nearly_equal :: proc(actual, expected: f32) -> bool {
	difference := actual - expected
	if difference < 0 { difference = -difference }
	return difference < 0.001
}

main :: proc() {
	scalar := tween.make(1, tween.ease_linear)
	tween.update(&scalar, 0.25)
	if !nearly_equal(tween.value_f32(&scalar, 10, 30), 15) { fmt.eprintln("scalar tween did not interpolate correctly"); return }

	vector := tween.make(1, tween.ease_in_out_quad)
	tween.update(&vector, 0.5)
	value := tween.value_vec3(&vector, {0, 0, 0}, {10, 20, 30})
	if !nearly_equal(value[0], 5) || !nearly_equal(value[1], 10) || !nearly_equal(value[2], 15) { fmt.eprintln("vector tween did not interpolate correctly"); return }

	ping_pong := tween.make(1)
	ping_pong.mode = .Ping_Pong
	ping_pong.repeat = 1
	tween.update(&ping_pong, 1.5)
	if !nearly_equal(tween.progress(&ping_pong), 0.5) || tween.is_complete(&ping_pong) { fmt.eprintln("ping-pong tween did not reverse correctly"); return }
	tween.update(&ping_pong, 0.5)
	if !tween.is_complete(&ping_pong) || !nearly_equal(tween.progress(&ping_pong), 0) { fmt.eprintln("ping-pong tween did not complete correctly"); return }

	fmt.println("tween validation passed")
}
