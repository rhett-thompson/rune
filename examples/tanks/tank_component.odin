package main

import "core:encoding/json"
import "rune:ecs"
import rl "vendor:raylib"

Tank :: struct {
	position, spawn: rl.Vector2,
	angle, spawn_angle: f32,
	radius, move_speed, turn_speed: f32,
	fire_cooldown, cooldown: f32,
	max_shot_bounces: i32,
	input_prefix: string,
	computer: bool,
	body_color, tread_color: [4]u8,
	alive: bool,
}

tank_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Tank, bool) {
	value, found := ecs.get_component(world, entity, "Tank")
	if !found { return {}, false }
	data, err := json.marshal(value)
	if err != nil { return {}, false }
	defer delete(data)
	result: Tank
	ok := json.unmarshal(data, &result) == nil && result.radius > 0 &&
	      result.move_speed > 0 && result.turn_speed > 0 && result.fire_cooldown > 0 &&
	      result.max_shot_bounces >= 0
	return result, ok
}
