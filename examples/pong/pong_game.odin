package main

import "core:fmt"
import "core:math"
import "core:strings"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

Pong_Game :: struct {
	arena: Pong_Arena,
	left, right: Pong_Paddle,
	ball: Pong_Ball,
	match: Pong_Match,
	hit_audio, start_audio, goal_audio, music_audio: ecs.Entity,
}

load_pong_game :: proc(game: ^Pong_Game, world: ^ecs.World) -> bool {
	arenas := ecs.entities_with_component(world, "PongArena")
	paddles := ecs.entities_with_component(world, "PongPaddle")
	balls := ecs.entities_with_component(world, "PongBall")
	matches := ecs.entities_with_component(world, "PongMatch")
	if len(arenas) != 1 || len(paddles) != 2 || len(balls) != 1 || len(matches) != 1 { return false }
	ok_a, ok_b, ok_m: bool
	game.arena, ok_a = arena_from_entity(world, arenas[0])
	game.ball, ok_b = ball_from_entity(world, balls[0])
	game.match, ok_m = match_from_entity(world, matches[0])
	first, ok_1 := paddle_from_entity(world, paddles[0])
	second, ok_2 := paddle_from_entity(world, paddles[1])
	if !ok_a || !ok_b || !ok_m || !ok_1 || !ok_2 || first.computer == second.computer { return false }
	if first.computer { game.right, game.left = first, second } else { game.left, game.right = first, second }
	game.hit_audio, ok_1 = ecs.find_entity_by_id(world, "hit_audio")
	game.start_audio, ok_2 = ecs.find_entity_by_id(world, "start_audio")
	game.goal_audio, ok_a = ecs.find_entity_by_id(world, "goal_audio")
	game.music_audio, ok_b = ecs.find_entity_by_id(world, "music_audio")
	return ok_1 && ok_2 && ok_a && ok_b
}

reset_ball :: proc(game: ^Pong_Game) {
	game.ball.position = {f32(game.arena.width) / 2, f32(game.arena.height) / 2}
	game.ball.velocity = {}
	game.match.serving = true
}

reset_match :: proc(game: ^Pong_Game) {
	game.left.y, game.right.y = f32(game.arena.height) / 2, f32(game.arena.height) / 2
	game.match.left_score, game.match.right_score = 0, 0
	game.match.game_over = false
	game.match.serve_to_left = rl.GetRandomValue(0, 1) == 0
	reset_ball(game)
}

paddle_hit :: proc(game: ^Pong_Game, paddle: Pong_Paddle, moving_left: bool) -> bool {
	b := game.ball
	if moving_left {
		if b.position.x - b.radius > paddle.x + f32(paddle.width) / 2 || b.position.x < paddle.x { return false }
	} else if b.position.x + b.radius < paddle.x - f32(paddle.width) / 2 || b.position.x > paddle.x { return false }
	return b.position.y + b.radius >= paddle.y - f32(paddle.height) / 2 &&
	       b.position.y - b.radius <= paddle.y + f32(paddle.height) / 2
}

bounce :: proc(game: ^Pong_Game, paddle: Pong_Paddle, right: bool) {
	offset := clamp((game.ball.position.y - paddle.y) / (f32(paddle.height) / 2), -1, 1)
	speed := clamp(ball_speed(game.ball) + game.ball.speed_increase, game.ball.start_speed, game.ball.max_speed)
	x := f32(math.sqrt(f64(1 - offset * offset * .64)))
	direction: f32 = 1
	if !right { x, direction = -x, -1 }
	game.ball.velocity = {x * speed, offset * .8 * speed}
	game.ball.position.x = paddle.x + (f32(paddle.width) / 2 + game.ball.radius + 1) * direction
}

update_ball :: proc(game: ^Pong_Game, engine: ^rune.Engine, dt: f32) {
	game.ball.position += game.ball.velocity * dt
	top, bottom := f32(game.arena.border), f32(game.arena.height - game.arena.border)
	if game.ball.position.y - game.ball.radius <= top {
		game.ball.position.y, game.ball.velocity.y = top + game.ball.radius, math.abs(game.ball.velocity.y)
		rune.play_audio(engine, &world, game.hit_audio)
	} else if game.ball.position.y + game.ball.radius >= bottom {
		game.ball.position.y, game.ball.velocity.y = bottom - game.ball.radius, -math.abs(game.ball.velocity.y)
		rune.play_audio(engine, &world, game.hit_audio)
	}
	if game.ball.velocity.x < 0 && paddle_hit(game, game.left, true) {
		bounce(game, game.left, true)
		rune.play_audio(engine, &world, game.hit_audio)
	}
	if game.ball.velocity.x > 0 && paddle_hit(game, game.right, false) {
		bounce(game, game.right, false)
		rune.play_audio(engine, &world, game.hit_audio)
	}
	if game.ball.position.x < -game.ball.radius {
		game.match.right_score += 1
		rune.play_audio(engine, &world, game.goal_audio)
		game.match.serve_to_left = true
		game.match.goal_side = -1
		game.match.goal_flash_time = .75
		game.match.game_over = game.match.right_score >= game.match.win_score
		reset_ball(game)
	} else if game.ball.position.x > f32(game.arena.width) + game.ball.radius {
		game.match.left_score += 1
		rune.play_audio(engine, &world, game.goal_audio)
		game.match.serve_to_left = false
		game.match.goal_side = 1
		game.match.goal_flash_time = .75
		game.match.game_over = game.match.left_score >= game.match.win_score
		reset_ball(game)
	}
}

update_pong :: proc(game: ^Pong_Game, engine: ^rune.Engine) {
	controls := rune.input_state(engine)
	game.ball.pulse_time += engine.delta_time
	if game.ball.pulse_time >= 1.2 { game.ball.pulse_time -= 1.2 }
	game.match.goal_flash_time = max(0, game.match.goal_flash_time - engine.delta_time)
	if input.pressed(controls, "toggle_players") { game.match.two_player = !game.match.two_player }
	if input.pressed(controls, "restart") { reset_match(game) }
	if game.match.game_over {
		if input.pressed(controls, "serve") { reset_match(game) }
		return
	}
	move_paddle(&game.left, input.axis(controls, game.left.input_axis), engine.delta_time, game.arena)
	if game.match.two_player {
		move_paddle(&game.right, input.axis(controls, game.right.input_axis), engine.delta_time, game.arena)
	} else {
		target := game.ball.position.y
		if game.match.serving { target = f32(game.arena.height) / 2 }
		amount: f32
		if target - game.right.y > 8 { amount = 1 } else if target - game.right.y < -8 { amount = -1 }
		speed := game.right.speed
		game.right.speed = game.right.ai_speed
		move_paddle(&game.right, amount, engine.delta_time, game.arena)
		game.right.speed = speed
	}
	if game.match.serving {
		if input.pressed(controls, "serve") {
			launch_ball(&game.ball, game.match.serve_to_left)
			rune.play_audio(engine, &world, game.start_audio)
			game.match.serving = false
		}
	} else { update_ball(game, engine, engine.delta_time) }
}

center_text :: proc(text: string, width, y, size: i32, tint: rl.Color) {
	c, _ := strings.clone_to_cstring(text, context.temp_allocator)
	rl.DrawText(c, (width - rl.MeasureText(c, size)) / 2, y, size, tint)
}

draw_pong :: proc(game: ^Pong_Game) {
	a := game.arena
	line, text, muted := color(a.line_color), color(a.text_color), color(a.muted_text_color)
	rl.DrawRectangleLinesEx({f32(a.border), f32(a.border), f32(a.width - a.border * 2), f32(a.height - a.border * 2)}, 2, line)
	if game.match.goal_flash_time > 0 {
		progress := 1 - game.match.goal_flash_time / .75
		alpha := u8(clamp((1 - progress) * 180, 0, 255))
		glow_width := i32(38 + progress * 42)
		red := rl.Color{239, 55, 72, alpha}
		clear_red := rl.Color{239, 55, 72, 0}
		goal_x: i32
		if game.match.goal_side < 0 {
			goal_x = a.border
			rl.DrawRectangleGradientH(goal_x, a.border, glow_width, a.height - a.border * 2, red, clear_red)
		} else {
			goal_x = a.width - a.border - glow_width
			rl.DrawRectangleGradientH(goal_x, a.border, glow_width, a.height - a.border * 2, clear_red, red)
		}
		outset := progress * 14
		edge_x := f32(a.border) if game.match.goal_side < 0 else f32(a.width - a.border)
		rl.DrawRectangleLinesEx(
			{edge_x - outset, f32(a.border) - outset, outset * 2 + 2, f32(a.height - a.border * 2) + outset * 2},
			3,
			red,
		)
	}
	for y := a.border + 10; y < a.height - a.border - 10; y += 24 { rl.DrawRectangle(a.width / 2 - 2, y, 4, 13, line) }
	ls, rs := fmt.tprintf("%d", game.match.left_score), fmt.tprintf("%d", game.match.right_score)
	lc, _ := strings.clone_to_cstring(ls, context.temp_allocator)
	rc, _ := strings.clone_to_cstring(rs, context.temp_allocator)
	rl.DrawText(lc, a.width / 2 - 112 - rl.MeasureText(lc, 52) / 2, 28, 52, text)
	rl.DrawText(rc, a.width / 2 + 112 - rl.MeasureText(rc, 52) / 2, 28, 52, text)
	rl.DrawRectangle(i32(game.left.x) - game.left.width / 2, i32(game.left.y) - game.left.height / 2, game.left.width, game.left.height, color(a.left_color))
	rl.DrawRectangle(i32(game.right.x) - game.right.width / 2, i32(game.right.y) - game.right.height / 2, game.right.width, game.right.height, color(a.right_color))
	if game.match.serving && !game.match.game_over {
		progress := game.ball.pulse_time / 1.2
		pulse_radius := game.ball.radius + 4 + progress * 28
		pulse_alpha := u8(clamp((1 - progress) * 90, 0, 255))
		rl.DrawCircleV(game.ball.position, pulse_radius, {255, 255, 255, pulse_alpha})
	}
	rl.DrawCircleV(game.ball.position, game.ball.radius + 4, {255, 255, 255, 32})
	rl.DrawCircleV(game.ball.position, game.ball.radius, text)
	if game.match.game_over {
		winner := "LEFT PLAYER WINS" if game.match.left_score > game.match.right_score else ("RIGHT PLAYER WINS" if game.match.two_player else "COMPUTER WINS")
		rl.DrawRectangle(0, a.height / 2 - 66, a.width, 132, color(a.background_color))
		center_text(winner, a.width, a.height / 2 - 45, 34, text)
		center_text("SPACE: NEW MATCH", a.width, a.height / 2 + 8, 20, muted)
	} else if game.match.serving { center_text("PRESS SPACE TO SERVE", a.width, a.height / 2 - 12, 22, muted) }
	mode := "1 PLAYER  |  W/S TO MOVE" if !game.match.two_player else "2 PLAYERS  |  W/S + UP/DOWN"
	center_text(mode, a.width, a.height - 39, 16, muted)
	rl.DrawText("P: CHANGE PLAYERS", 22, a.height - 37, 14, muted)
	rl.DrawText("R: RESTART", a.width - 112, a.height - 37, 14, muted)
}
