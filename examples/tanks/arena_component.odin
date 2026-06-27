package main

import "core:encoding/json"
import "rune:ecs"
import rl "vendor:raylib"

Tanks_Arena :: struct {
	width, height, border: i32,
	background_color, grid_color, wall_color: [4]u8,
	text_color, muted_text_color: [4]u8,
	walls: [][4]f32,
}

arena_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Tanks_Arena, bool) {
	value, found := ecs.get_component(world, entity, "TanksArena")
	if !found { return {}, false }
	data, err := json.marshal(value)
	if err != nil { return {}, false }
	defer delete(data)
	result: Tanks_Arena
	ok := json.unmarshal(data, &result) == nil && result.width > 0 && result.height > 0 && result.border >= 0
	return result, ok
}

color :: proc(value: [4]u8) -> rl.Color { return {value[0], value[1], value[2], value[3]} }

wall_rectangle :: proc(value: [4]f32) -> rl.Rectangle {
	return {value[0], value[1], value[2], value[3]}
}
