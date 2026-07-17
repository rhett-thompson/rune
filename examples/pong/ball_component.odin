package main

import "core:math"
import "rune:ecs"
import rl "vendor:raylib"

Pong_Ball :: struct {
	position, velocity:                             rl.Vector2,
	radius, start_speed, max_speed, speed_increase: f32,
	pulse_time:                                     f32,
}

ball_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Pong_Ball, bool) {
	result, found := ecs.get(world, entity, Pong_Ball)
	ok :=
		found &&
		result.radius > 0 &&
		result.start_speed > 0 &&
		result.max_speed >= result.start_speed
	return result, ok
}

launch_ball :: proc(ball: ^Pong_Ball, left: bool) {
	x: f32 = 1
	if left {x = -1}
	y := f32(rl.GetRandomValue(-70, 70)) / 100
	length := f32(math.sqrt(f64(1 + y * y)))
	ball.velocity = {x / length * ball.start_speed, y / length * ball.start_speed}
}

ball_speed :: proc(ball: Pong_Ball) -> f32 {
	return f32(
		math.sqrt(f64(ball.velocity.x * ball.velocity.x + ball.velocity.y * ball.velocity.y)),
	)
}
