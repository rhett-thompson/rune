package main

import "core:encoding/json"
import "rune:ecs"

Pong_Match :: struct {
	left_score, right_score, win_score: i32,
	serving, game_over, two_player, serve_to_left: bool,
	goal_flash_time: f32,
	goal_side: i32,
}

match_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Pong_Match, bool) {
	value, found := ecs.get_component(world, entity, "PongMatch")
	if !found { return {}, false }
	data, err := json.marshal(value)
	if err != nil { return {}, false }
	defer delete(data)
	result: Pong_Match
	ok := json.unmarshal(data, &result) == nil && result.win_score > 0
	return result, ok
}
