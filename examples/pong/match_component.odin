package main

import "rune:ecs"

Pong_Match :: struct {
	left_score, right_score, win_score:            i32,
	serving, game_over, two_player, serve_to_left: bool,
	goal_flash_time:                               f32,
	goal_side:                                     i32,
}

match_from_entity :: proc(world: ^ecs.World, entity: ecs.Entity) -> (Pong_Match, bool) {
	result, found := ecs.get(world, entity, Pong_Match)
	ok := found && result.win_score > 0
	return result, ok
}
