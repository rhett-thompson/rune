package main

import "rune:ecs"
import rl "vendor:raylib"

Pong_Arena :: struct {
	width, height, border:                                 i32,
	background_color, line_color, left_color, right_color: [4]u8,
	text_color, muted_text_color:                          [4]u8,
}

arena_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Pong_Arena, bool) {
	result, found := ecs.get(world, entity, Pong_Arena)
	ok := found && result.width > 0 && result.height > 0
	return result, ok
}

color :: proc(value: [4]u8) -> rl.Color {return {value[0], value[1], value[2], value[3]}}
