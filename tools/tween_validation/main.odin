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
	assert(nearly_equal(tween.value_f32(&scalar, 10, 30), 15), "scalar tween did not interpolate correctly")

	vector := tween.make(1, tween.ease_in_out_quad)
	tween.update(&vector, 0.5)
	value := tween.value_vec3(&vector, {0, 0, 0}, {10, 20, 30})
	assert(nearly_equal(value[0], 5) && nearly_equal(value[1], 10) && nearly_equal(value[2], 15), "vector tween did not interpolate correctly")

	ping_pong := tween.make(1)
	ping_pong.mode = .Ping_Pong
	ping_pong.repeat = 1
	tween.update(&ping_pong, 1.5)
	assert(nearly_equal(tween.progress(&ping_pong), 0.5) && !tween.is_complete(&ping_pong), "ping-pong tween did not reverse correctly")
	tween.update(&ping_pong, 0.5)
	assert(tween.is_complete(&ping_pong) && nearly_equal(tween.progress(&ping_pong), 0), "ping-pong tween did not complete correctly")

	assert(tween.ease_in_elastic(0) == 0 && tween.ease_in_elastic(1) == 1)
	assert(nearly_equal(tween.ease_in_elastic(0.9999), 1), "elastic ease-in must approach its final value continuously")
	for index in 0 ..= 100 {
		t := f32(index) / 100
		assert(nearly_equal(tween.ease_in_elastic(t), 1 - tween.ease_out_elastic(1 - t)), "elastic ease-in must mirror ease-out")
	}

	fmt.println("tween validation passed")
}
