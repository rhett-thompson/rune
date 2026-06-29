package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

MAX_ASTEROIDS :: 96
MAX_BULLETS :: 32
TAU :: f32(math.PI * 2)

Ship :: struct {
	position, velocity: rl.Vector2,
	angle, fire_timer, invulnerable, respawn_timer: f32,
	alive: bool,
}

Bullet :: struct {
	position, velocity: rl.Vector2,
	life: f32,
}

Particle :: struct {
	position, velocity: rl.Vector2,
	life, max_life, size: f32,
}

Game :: struct {
	arena: Arena_Config,
	ship_config: Ship_Config,
	spawner: Asteroid_Spawner,
	ship: Ship,
	asteroids: [dynamic]Asteroid_Instance,
	bullets: [dynamic]Bullet,
	particles: [dynamic]Particle,
	score, lives, wave: i32,
	game_over: bool,
}

color :: proc(value: [4]u8) -> rl.Color {
	return {value[0], value[1], value[2], value[3]}
}

component_into :: proc(world: ^ecs.World, name: string, result: ^$T) -> bool {
	entities := ecs.entities_with_component(world, name)
	if len(entities) != 1 { return false }
	value, found := ecs.get_component(world, entities[0], name)
	if !found { return false }
	data, err := json.marshal(value)
	if err != nil { return false }
	defer delete(data)
	return json.unmarshal(data, result) == nil
}

direction :: proc(angle: f32) -> rl.Vector2 {
	return {f32(math.cos(f64(angle))), f32(math.sin(f64(angle)))}
}

length_squared :: proc(value: rl.Vector2) -> f32 {
	return value.x * value.x + value.y * value.y
}

wrap_position :: proc(position: ^rl.Vector2, width, height: f32) {
	if position.x < 0 { position.x += width }
	if position.x >= width { position.x -= width }
	if position.y < 0 { position.y += height }
	if position.y >= height { position.y -= height }
}

wrapped_delta :: proc(a, b: rl.Vector2, width, height: f32) -> rl.Vector2 {
	d := a - b
	if d.x > width / 2 { d.x -= width } else if d.x < -width / 2 { d.x += width }
	if d.y > height / 2 { d.y -= height } else if d.y < -height / 2 { d.y += height }
	return d
}

random_edge_position :: proc(game: ^Game) -> rl.Vector2 {
	width, height := game.arena.width, game.arena.height
	side := rl.GetRandomValue(0, 3)
	if side == 0 { return {f32(rl.GetRandomValue(0, width)), 0} }
	if side == 1 { return {f32(width), f32(rl.GetRandomValue(0, height))} }
	if side == 2 { return {f32(rl.GetRandomValue(0, width)), f32(height)} }
	return {0, f32(rl.GetRandomValue(0, height))}
}

reset_ship :: proc(game: ^Game) {
	game.ship = {
		position = game.ship_config.position,
		angle = -f32(math.PI) / 2,
		invulnerable = game.spawner.invulnerable_time,
		alive = true,
	}
}

reset_game :: proc(game: ^Game) {
	clear_asteroids(game)
	clear(&game.bullets)
	clear(&game.particles)
	game.score = 0
	game.wave = 0
	game.lives = game.spawner.starting_lives
	game.game_over = false
	reset_ship(game)
	spawn_wave(game)
}

emit_particles :: proc(game: ^Game, position: rl.Vector2, count: i32, speed: f32) {
	for _ in 0 ..< count {
		angle := f32(rl.GetRandomValue(0, 6283)) / 1000
		life := f32(rl.GetRandomValue(30, 90)) / 100
		append(&game.particles, Particle{
			position = position,
			velocity = direction(angle) * f32(rl.GetRandomValue(i32(speed / 3), i32(speed))),
			life = life,
			max_life = life,
			size = f32(rl.GetRandomValue(1, 4)),
		})
	}
}

destroy_ship :: proc(game: ^Game) {
	if !game.ship.alive || game.ship.invulnerable > 0 { return }
	emit_particles(game, game.ship.position, 24, 190)
	game.ship.alive = false
	game.ship.respawn_timer = game.spawner.respawn_delay
	game.lives -= 1
	if game.lives <= 0 { game.game_over = true }
}

fire :: proc(game: ^Game) {
	if game.ship.fire_timer > 0 || len(game.bullets) >= MAX_BULLETS { return }
	dir := direction(game.ship.angle)
	append(&game.bullets, Bullet{
		position = game.ship.position + dir * (game.ship_config.radius + 5),
		velocity = game.ship.velocity + dir * game.ship_config.bullet_speed,
		life = game.ship_config.bullet_life,
	})
	game.ship.fire_timer = game.ship_config.fire_delay
}

update_particles :: proc(game: ^Game, dt: f32) {
	for i := len(game.particles) - 1; i >= 0; i -= 1 {
		p := &game.particles[i]
		p.life -= dt
		p.position += p.velocity * dt
		p.velocity *= f32(math.pow(.12, f64(dt)))
		wrap_position(&p.position, f32(game.arena.width), f32(game.arena.height))
		if p.life <= 0 { unordered_remove(&game.particles, i) }
	}
}

update_ship :: proc(game: ^Game, controls: ^input.Input, dt: f32) {
	ship := &game.ship
	ship.fire_timer = max(0, ship.fire_timer - dt)
	ship.invulnerable = max(0, ship.invulnerable - dt)
	if !ship.alive {
		if game.game_over { return }
		ship.respawn_timer -= dt
		if ship.respawn_timer <= 0 { reset_ship(game) }
		return
	}
	ship.angle += input.axis(controls, "turn") * game.ship_config.turn_speed * dt
	if input.is_down(controls, "thrust") {
		dir := direction(ship.angle)
		ship.velocity += dir * game.ship_config.thrust * dt
		if rl.GetRandomValue(0, 2) == 0 {
			append(&game.particles, Particle{
				position = ship.position - dir * game.ship_config.radius,
				velocity = ship.velocity - dir * f32(rl.GetRandomValue(80, 150)),
				life = .25, max_life = .25, size = 2,
			})
		}
	}
	ship.velocity *= f32(math.pow(f64(game.ship_config.drag), f64(dt)))
	speed_sq := length_squared(ship.velocity)
	if speed_sq > game.ship_config.max_speed * game.ship_config.max_speed {
		ship.velocity *= game.ship_config.max_speed / f32(math.sqrt(f64(speed_sq)))
	}
	ship.position += ship.velocity * dt
	wrap_position(&ship.position, f32(game.arena.width), f32(game.arena.height))
	if input.is_down(controls, "fire") { fire(game) }
}

update_asteroids :: proc(game: ^Game, dt: f32) {
	for &instance in game.asteroids {
		asteroid := &instance.component
		asteroid.position += asteroid.velocity * dt
		asteroid.angle += asteroid.spin * dt
		wrap_position(&asteroid.position, f32(game.arena.width), f32(game.arena.height))
		if game.ship.alive && game.ship.invulnerable <= 0 {
			d := wrapped_delta(asteroid.position, game.ship.position, f32(game.arena.width), f32(game.arena.height))
			r := asteroid.radius * .82 + game.ship_config.radius
			if length_squared(d) < r * r { destroy_ship(game) }
		}
	}
}

update_bullets :: proc(game: ^Game, dt: f32) {
	for i := len(game.bullets) - 1; i >= 0; i -= 1 {
		bullet := &game.bullets[i]
		bullet.life -= dt
		bullet.position += bullet.velocity * dt
		wrap_position(&bullet.position, f32(game.arena.width), f32(game.arena.height))
		hit := -1
		for instance, index in game.asteroids {
			asteroid := instance.component
			d := wrapped_delta(asteroid.position, bullet.position, f32(game.arena.width), f32(game.arena.height))
			if length_squared(d) <= asteroid.radius * asteroid.radius { hit = index; break }
		}
		if hit >= 0 {
			asteroid := game.asteroids[hit].component
			game.score += 25 * (4 - asteroid.tier)
			emit_particles(game, asteroid.position, 5 + asteroid.tier * 3, 120)
			remove_asteroid(game, hit)
			if asteroid.tier > 1 {
				spawn_asteroid(game, asteroid.position + {-5, 3}, asteroid.tier - 1)
				spawn_asteroid(game, asteroid.position + {5, -3}, asteroid.tier - 1)
			}
			unordered_remove(&game.bullets, i)
		} else if bullet.life <= 0 {
			unordered_remove(&game.bullets, i)
		}
	}
}

update_game :: proc(engine: ^rune.Engine) {
	controls := rune.input_state(engine)
	if input.pressed(controls, "restart") { reset_game(&game); return }
	if game.game_over { return }
	update_ship(&game, controls, engine.delta_time)
	update_asteroids(&game, engine.delta_time)
	update_bullets(&game, engine.delta_time)
	update_particles(&game, engine.delta_time)
	if len(game.asteroids) == 0 { spawn_wave(&game) }
}

draw_wrapped_line :: proc(a, b: rl.Vector2, tint: rl.Color) {
	rl.DrawLineEx(a, b, 2, tint)
}

draw_ship :: proc(game: ^Game) {
	if !game.ship.alive { return }
	if game.ship.invulnerable > 0 && i32(game.ship.invulnerable * 12) % 2 == 0 { return }
	s := game.ship
	dir := direction(s.angle)
	side := direction(s.angle + f32(math.PI) * .72)
	side_2 := direction(s.angle - f32(math.PI) * .72)
	nose := s.position + dir * (game.ship_config.radius * 1.35)
	left := s.position + side * game.ship_config.radius
	right := s.position + side_2 * game.ship_config.radius
	back := s.position - dir * (game.ship_config.radius * .45)
	tint := color(game.arena.line_color)
	draw_wrapped_line(nose, left, tint)
	draw_wrapped_line(left, back, tint)
	draw_wrapped_line(back, right, tint)
	draw_wrapped_line(right, nose, tint)
}

draw_asteroid :: proc(asteroid: Asteroid_Component, tint: rl.Color) {
	vertex_count := 10
	previous: rl.Vector2
	for i in 0 ..= vertex_count {
		index := i % vertex_count
		noise := f32(((asteroid.seed + i32(index) * 47) % 29) - 14) / 100
		angle := asteroid.angle + f32(index) / f32(vertex_count) * TAU
		point := asteroid.position + direction(angle) * asteroid.radius * (1 + noise)
		if i > 0 { rl.DrawLineEx(previous, point, 2, tint) }
		previous = point
	}
}

draw_centered :: proc(text: string, y, size, width: i32, tint: rl.Color) {
	c_text, _ := strings.clone_to_cstring(text, context.temp_allocator)
	rl.DrawText(c_text, (width - rl.MeasureText(c_text, size)) / 2, y, size, tint)
}

draw_game :: proc(engine: ^rune.Engine) {
	line := color(game.arena.line_color)
	accent := color(game.arena.accent_color)
	muted := color(game.arena.muted_color)
	for i in 0 ..< game.arena.star_count {
		x := (i * 97 + 31) % game.arena.width
		y := (i * 53 + 17) % game.arena.height
		brightness := u8(45 + (i * 37) % 75)
		rl.DrawPixel(x, y, {line.r, line.g, line.b, brightness})
	}
	for asteroid in game.asteroids { draw_asteroid(asteroid.component, line) }
	for bullet in game.bullets {
		rl.DrawCircleV(bullet.position, 2.5, accent)
		rl.DrawCircleV(bullet.position, 6, {accent.r, accent.g, accent.b, 36})
	}
	for particle in game.particles {
		alpha := u8(clamp(particle.life / particle.max_life * 220, 0, 220))
		rl.DrawCircleV(particle.position, particle.size, {accent.r, accent.g, accent.b, alpha})
	}
	draw_ship(&game)
	score_text := fmt.tprintf("SCORE  %06d", game.score)
	wave_text := fmt.tprintf("WAVE  %02d", game.wave)
	lives_text := fmt.tprintf("SHIPS  %d", game.lives)
	score_c, _ := strings.clone_to_cstring(score_text, context.temp_allocator)
	wave_c, _ := strings.clone_to_cstring(wave_text, context.temp_allocator)
	lives_c, _ := strings.clone_to_cstring(lives_text, context.temp_allocator)
	rl.DrawText(score_c, 22, 18, 20, line)
	rl.DrawText(wave_c, game.arena.width / 2 - rl.MeasureText(wave_c, 20) / 2, 18, 20, muted)
	rl.DrawText(lives_c, game.arena.width - rl.MeasureText(lives_c, 20) - 22, 18, 20, line)
	rl.DrawText("A/D OR ARROWS: TURN   W/UP: THRUST   SPACE: FIRE   R: RESTART", 22, game.arena.height - 28, 14, muted)
	if game.game_over {
		rl.DrawRectangle(0, game.arena.height / 2 - 70, game.arena.width, 140, {5, 8, 18, 230})
		draw_centered("GAME OVER", game.arena.height / 2 - 48, 40, game.arena.width, accent)
		draw_centered("PRESS R TO RESTART", game.arena.height / 2 + 12, 19, game.arena.width, line)
	} else if !game.ship.alive {
		draw_centered("SHIP DESTROYED", game.arena.height / 2 - 20, 22, game.arena.width, muted)
	}
}
