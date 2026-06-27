package main

import "core:encoding/json"
import "rune:ecs"
import rl "vendor:raylib"

Pong_Arena :: struct {
	width, height, border: i32,
	background_color, line_color, left_color, right_color: [4]u8,
	text_color, muted_text_color: [4]u8,
}

arena_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Pong_Arena, bool) {
	value, found := ecs.get_component(world, entity, "PongArena")
	if !found { return {}, false }
	data, err := json.marshal(value)
	if err != nil { return {}, false }
	defer delete(data)
	result: Pong_Arena
	ok := json.unmarshal(data, &result) == nil && result.width > 0 && result.height > 0
	return result, ok
}

color :: proc(value: [4]u8) -> rl.Color { return {value[0], value[1], value[2], value[3]} }
