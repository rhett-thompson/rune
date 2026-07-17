package main

import "rune:ecs"

Tanks_Match :: struct {
	left_score, right_score, win_score: i32,
	two_player, game_over: bool,
	round_delay, round_timer: f32,
	winner: i32,
}

match_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Tanks_Match, bool) {
	result, found := ecs.get(world, entity, Tanks_Match)
	if !found { return {}, false }
	ok := result.win_score > 0 && result.round_delay > 0
	return result, ok
}
