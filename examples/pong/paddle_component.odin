package main

import "core:encoding/json"
import "rune:ecs"

Pong_Paddle :: struct {
	x, y: f32,
	width, height: i32,
	speed, ai_speed: f32,
	input_axis: string,
	computer: bool,
}

paddle_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Pong_Paddle, bool) {
	value, found := ecs.get_component(world, entity, "PongPaddle")
	if !found { return {}, false }
	data, err := json.marshal(value)
	if err != nil { return {}, false }
	defer delete(data)
	result: Pong_Paddle
	ok := json.unmarshal(data, &result) == nil && result.width > 0 && result.height > 0 && result.speed > 0
	return result, ok
}

move_paddle :: proc(paddle: ^Pong_Paddle, amount, dt: f32, arena: Pong_Arena) {
	paddle.y += amount * paddle.speed * dt
	half := f32(paddle.height) / 2
	paddle.y = clamp(paddle.y, half + f32(arena.border), f32(arena.height - arena.border) - half)
}
