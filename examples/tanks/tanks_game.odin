package main

import "core:fmt"
import "core:math"
import "core:strings"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

Shell :: struct {
	position, velocity: rl.Vector2,
	owner: i32,
	life: f32,
	bounces, max_bounces: i32,
}

Explosion :: struct {
	position: rl.Vector2,
	age, duration: f32,
}

Tanks_Game :: struct {
	arena: Tanks_Arena,
	left, right: Tank,
	match: Tanks_Match,
	shells: [dynamic]Shell,
	explosions: [dynamic]Explosion,
	flash_time: f32,
}

load_tanks_game :: proc(game: ^Tanks_Game, world: ^ecs.World) -> bool {
	arenas := ecs.entities_with_component(world, "TanksArena")
	tanks := ecs.entities_with_component(world, "Tank")
	matches := ecs.entities_with_component(world, "TanksMatch")
	if len(arenas) != 1 || len(tanks) != 2 || len(matches) != 1 { return false }
	ok_a, ok_m: bool
	game.arena, ok_a = arena_from_entity(world, arenas[0])
	game.match, ok_m = match_from_entity(world, matches[0])
	first, ok_1 := tank_from_entity(world, tanks[0])
	second, ok_2 := tank_from_entity(world, tanks[1])
	if !ok_a || !ok_m || !ok_1 || !ok_2 {
		fmt.eprintf("Invalid Tanks components: arena=%v match=%v tank_1=%v tank_2=%v\n", ok_a, ok_m, ok_1, ok_2)
		return false
	}
	if first.computer == second.computer {
		fmt.eprintln("Tanks scene must define exactly one computer-controlled tank")
		return false
	}
	if first.computer { game.right, game.left = first, second } else { game.left, game.right = first, second }
	game.shells = make([dynamic]Shell)
	game.explosions = make([dynamic]Explosion)
	return true
}

direction :: proc(angle: f32) -> rl.Vector2 {
	radians := angle * f32(math.PI) / 180
	return {f32(math.cos(f64(radians))), f32(math.sin(f64(radians)))}
}

circle_hits_rect :: proc(position: rl.Vector2, radius: f32, rect: rl.Rectangle) -> bool {
	x := clamp(position.x, rect.x, rect.x + rect.width)
	y := clamp(position.y, rect.y, rect.y + rect.height)
	dx, dy := position.x - x, position.y - y
	return dx * dx + dy * dy < radius * radius
}

position_blocked :: proc(game: ^Tanks_Game, position: rl.Vector2, radius: f32) -> bool {
	a := game.arena
	if position.x - radius < f32(a.border) || position.x + radius > f32(a.width - a.border) ||
	   position.y - radius < f32(a.border) || position.y + radius > f32(a.height - a.border) { return true }
	for wall in a.walls {
		if circle_hits_rect(position, radius, wall_rectangle(wall)) { return true }
	}
	return false
}

reset_round :: proc(game: ^Tanks_Game) {
	for shell in game.shells {
		append(&game.explosions, Explosion{position = shell.position, duration = .32})
	}
	clear(&game.shells)
	game.left.position, game.left.angle, game.left.alive = game.left.spawn, game.left.spawn_angle, true
	game.right.position, game.right.angle, game.right.alive = game.right.spawn, game.right.spawn_angle, true
	game.left.cooldown, game.right.cooldown = .5, .5
	game.match.winner, game.match.round_timer = 0, 0
}

reset_match :: proc(game: ^Tanks_Game) {
	game.match.left_score, game.match.right_score = 0, 0
	game.match.game_over = false
	reset_round(game)
}

move_tank :: proc(game: ^Tanks_Game, tank: ^Tank, move, turn, dt: f32) {
	tank.angle += turn * tank.turn_speed * dt
	for tank.angle < 0 { tank.angle += 360 }
	for tank.angle >= 360 { tank.angle -= 360 }
	next := tank.position + direction(tank.angle) * move * tank.move_speed * dt
	if !position_blocked(game, {next.x, tank.position.y}, tank.radius) { tank.position.x = next.x }
	if !position_blocked(game, {tank.position.x, next.y}, tank.radius) { tank.position.y = next.y }
}

fire_shell :: proc(game: ^Tanks_Game, tank: ^Tank, owner: i32) {
	if tank.cooldown > 0 || !tank.alive { return }
	dir := direction(tank.angle)
	muzzle := tank.position + dir * (tank.radius + 12)
	if position_blocked(game, muzzle, 4) { return }
	append(&game.shells, Shell{
		position = muzzle,
		velocity = dir * 390,
		owner = owner,
		life = 5,
		max_bounces = tank.max_shot_bounces,
	})
	tank.cooldown = tank.fire_cooldown
}

angle_delta :: proc(from, to: f32) -> f32 {
	result := to - from
	for result > 180 { result -= 360 }
	for result < -180 { result += 360 }
	return result
}

ai_shot_hits_player :: proc(game: ^Tanks_Game, angle: f32) -> bool {
	dir := direction(angle)
	shell := Shell{
		position = game.right.position + dir * (game.right.radius + 12),
		velocity = dir * 390,
		owner = 2,
		life = 5,
		max_bounces = game.right.max_shot_bounces,
	}
	if position_blocked(game, shell.position, 4) { return false }

	// Use a fixed, small step so the prediction follows the same ricochet rules
	// without tunneling through tanks or narrow walls.
	step: f32 = 1.0 / 120.0
	for shell.life > 0 && shell.bounces <= shell.max_bounces {
		shell.life -= step
		shell_hits_wall(game, &shell, step)
		if shell_hits_tank(shell, game.right) { return false }
		if shell_hits_tank(shell, game.left) { return true }
	}
	return false
}

find_ai_shot :: proc(game: ^Tanks_Game, direct_angle: f32) -> (f32, bool) {
	if ai_shot_hits_player(game, direct_angle) { return direct_angle, true }

	// Search outward from the direct bearing. This finds useful one- or
	// multi-wall bank shots while preferring the shortest turn.
	for offset: f32 = 5; offset <= 180; offset += 5 {
		left_angle := direct_angle - offset
		if ai_shot_hits_player(game, left_angle) { return left_angle, true }
		right_angle := direct_angle + offset
		if ai_shot_hits_player(game, right_angle) { return right_angle, true }
	}
	return 0, false
}

update_ai :: proc(game: ^Tanks_Game, dt: f32) {
	tank, target := &game.right, game.left.position
	delta := target - tank.position
	desired := f32(math.atan2(f64(delta.y), f64(delta.x))) * 180 / f32(math.PI)
	shot_available := false
	if tank.cooldown <= 0 {
		shot_angle: f32
		shot_angle, shot_available = find_ai_shot(game, desired)
		if shot_available { desired = shot_angle }
	}
	error := angle_delta(tank.angle, desired)
	turn: f32
	if error > 3 { turn = 1 } else if error < -3 { turn = -1 }
	move: f32 = 1
	distance_sq := delta.x * delta.x + delta.y * delta.y
	if distance_sq < 150 * 150 { move = -.45 }
	move_tank(game, tank, move, turn, dt)
	if shot_available && math.abs(error) < 3 { fire_shell(game, tank, 2) }
}

shell_hits_wall :: proc(game: ^Tanks_Game, shell: ^Shell, dt: f32) {
	next := shell.position + shell.velocity * dt
	hit_x := position_blocked(game, {next.x, shell.position.y}, 4)
	hit_y := position_blocked(game, {shell.position.x, next.y}, 4)
	if hit_x { shell.velocity.x = -shell.velocity.x; shell.bounces += 1 }
	if hit_y { shell.velocity.y = -shell.velocity.y; shell.bounces += 1 }
	if !hit_x { shell.position.x = next.x }
	if !hit_y { shell.position.y = next.y }
	if hit_x && hit_y { shell.bounces -= 1 }
}

shell_hits_tank :: proc(shell: Shell, tank: Tank) -> bool {
	if !tank.alive { return false }
	d := shell.position - tank.position
	r := tank.radius + 4
	return d.x * d.x + d.y * d.y <= r * r
}

end_round :: proc(game: ^Tanks_Game, winner: i32) {
	game.match.winner = winner
	game.match.round_timer = game.match.round_delay
	game.flash_time = .35
	if winner == 1 { game.match.left_score += 1 } else { game.match.right_score += 1 }
	game.match.game_over = game.match.left_score >= game.match.win_score || game.match.right_score >= game.match.win_score
}

update_shells :: proc(game: ^Tanks_Game, dt: f32) {
	for i := len(game.shells) - 1; i >= 0; i -= 1 {
		shell := &game.shells[i]
		shell.life -= dt
		shell_hits_wall(game, shell, dt)
		hit := shell.bounces > shell.max_bounces || shell.life <= 0
		if !hit && shell_hits_tank(shell^, game.left) {
			game.left.alive = false
			end_round(game, 2)
			hit = true
		} else if !hit && shell_hits_tank(shell^, game.right) {
			game.right.alive = false
			end_round(game, 1)
			hit = true
		}
		if hit {
			append(&game.explosions, Explosion{position = shell.position, duration = .32})
			unordered_remove(&game.shells, i)
		}
	}
}

update_explosions :: proc(game: ^Tanks_Game, dt: f32) {
	for i := len(game.explosions) - 1; i >= 0; i -= 1 {
		game.explosions[i].age += dt
		if game.explosions[i].age >= game.explosions[i].duration {
			unordered_remove(&game.explosions, i)
		}
	}
}

update_tanks :: proc(game: ^Tanks_Game, engine: ^rune.Engine) {
	controls := rune.input_state(engine)
	game.flash_time = max(0, game.flash_time - engine.delta_time)
	update_explosions(game, engine.delta_time)
	if input.pressed(controls, "toggle_players") { game.match.two_player = !game.match.two_player; reset_match(game) }
	if input.pressed(controls, "restart") { reset_match(game) }
	if game.match.winner != 0 {
		if game.match.game_over {
			if input.pressed(controls, "left_fire") || input.pressed(controls, "right_fire") { reset_match(game) }
			return
		}
		game.match.round_timer -= engine.delta_time
		if game.match.round_timer <= 0 { reset_round(game) }
		return
	}
	game.left.cooldown = max(0, game.left.cooldown - engine.delta_time)
	game.right.cooldown = max(0, game.right.cooldown - engine.delta_time)
	move_tank(game, &game.left, input.axis(controls, "left_move"), input.axis(controls, "left_turn"), engine.delta_time)
	if input.pressed(controls, "left_fire") { fire_shell(game, &game.left, 1) }
	if game.match.two_player {
		move_tank(game, &game.right, input.axis(controls, "right_move"), input.axis(controls, "right_turn"), engine.delta_time)
		if input.pressed(controls, "right_fire") { fire_shell(game, &game.right, 2) }
	} else { update_ai(game, engine.delta_time) }
	update_shells(game, engine.delta_time)
}

center_text :: proc(text: string, width, y, size: i32, tint: rl.Color) {
	c, _ := strings.clone_to_cstring(text, context.temp_allocator)
	rl.DrawText(c, (width - rl.MeasureText(c, size)) / 2, y, size, tint)
}

draw_tank :: proc(tank: Tank) {
	if !tank.alive { return }
	dir := direction(tank.angle)
	side := rl.Vector2{-dir.y, dir.x}
	tread := color(tank.tread_color)
	body := color(tank.body_color)
	for sign: f32 = -1; sign <= 1; sign += 2 {
		center := tank.position + side * sign * (tank.radius - 3)
		rl.DrawRectanglePro({center.x, center.y, tank.radius * 1.55, 7}, {tank.radius * .775, 3.5}, tank.angle, tread)
	}
	rl.DrawCircleV(tank.position, tank.radius - 3, body)
	rl.DrawCircleLinesV(tank.position, tank.radius - 3, tread)
	rl.DrawLineEx(tank.position, tank.position + dir * (tank.radius + 15), 7, tread)
	rl.DrawCircleV(tank.position, 7, body)
}

draw_tanks :: proc(game: ^Tanks_Game) {
	a := game.arena
	grid, wall := color(a.grid_color), color(a.wall_color)
	for x: i32 = 30; x < a.width; x += 30 { rl.DrawLine(x, 0, x, a.height, grid) }
	for y: i32 = 30; y < a.height; y += 30 { rl.DrawLine(0, y, a.width, y, grid) }
	rl.DrawRectangleLinesEx({f32(a.border), f32(a.border), f32(a.width - a.border * 2), f32(a.height - a.border * 2)}, f32(a.border), wall)
	for obstacle in a.walls {
		rect := wall_rectangle(obstacle)
		rl.DrawRectangleRec(rect, wall)
		rl.DrawRectangleLinesEx(rect, 2, color(a.grid_color))
	}
	for shell in game.shells {
		shell_color := color(game.left.body_color)
		if shell.owner == 2 { shell_color = color(game.right.body_color) }
		glow_color := shell_color
		glow_color.a = 55
		rl.DrawCircleV(shell.position, 9, glow_color)
		rl.DrawCircleV(shell.position, 4, shell_color)
	}
	for explosion in game.explosions {
		progress := explosion.age / explosion.duration
		radius := 5 + progress * 22
		alpha := u8(clamp((1 - progress) * 210, 0, 255))
		rl.DrawCircleV(explosion.position, radius * .55, {239, 55, 72, alpha / 4})
		rl.DrawRing(explosion.position, radius - 2, radius, 0, 360, 28, {239, 55, 72, alpha})
	}
	draw_tank(game.left)
	draw_tank(game.right)
	text, muted := color(a.text_color), color(a.muted_text_color)
	score := fmt.tprintf("%d     :     %d", game.match.left_score, game.match.right_score)
	center_text(score, a.width, 15, 30, text)
	if game.flash_time > 0 { rl.DrawRectangle(0, 0, a.width, a.height, {255, 255, 255, u8(game.flash_time / .35 * 100)}) }
	if game.match.winner != 0 {
		label := "BLUE WINS THE ROUND" if game.match.winner == 1 else ("ORANGE WINS THE ROUND" if game.match.two_player else "COMPUTER WINS THE ROUND")
		if game.match.game_over {
			label = "BLUE WINS THE MATCH" if game.match.winner == 1 else ("ORANGE WINS THE MATCH" if game.match.two_player else "COMPUTER WINS THE MATCH")
		}
		rl.DrawRectangle(0, a.height / 2 - 55, a.width, 110, {8, 12, 24, 225})
		center_text(label, a.width, a.height / 2 - 34, 30, text)
		if game.match.game_over { center_text("PRESS FIRE FOR A NEW MATCH", a.width, a.height / 2 + 8, 17, muted) }
	}
	mode := "1 PLAYER  |  W/S DRIVE  A/D TURN  SPACE FIRE" if !game.match.two_player else "2 PLAYERS  |  BLUE: WASD + SPACE   ORANGE: ARROWS + ENTER"
	center_text(mode, a.width, a.height - 28, 14, muted)
	rl.DrawText("P: CHANGE PLAYERS", 18, 17, 13, muted)
	rl.DrawText("R: RESTART", a.width - 96, 17, 13, muted)
}
