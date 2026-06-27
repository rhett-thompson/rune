package main

import "core:encoding/json"
import "rune:ecs"

Tanks_Match :: struct {
	left_score, right_score, win_score: i32,
	two_player, game_over: bool,
	round_delay, round_timer: f32,
	winner: i32,
}

match_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Tanks_Match, bool) {
	value, found := ecs.get_component(world, entity, "TanksMatch")
	if !found { return {}, false }
	data, err := json.marshal(value)
	if err != nil { return {}, false }
	defer delete(data)
	result: Tanks_Match
	ok := json.unmarshal(data, &result) == nil && result.win_score > 0 && result.round_delay > 0
	return result, ok
}
