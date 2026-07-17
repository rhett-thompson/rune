package main

import "rune:ecs"
import rl "vendor:raylib"

spawn_asteroid :: proc(game: ^Game, position: rl.Vector2, tier: i32) {
	if len(game.asteroids) >= MAX_ASTEROIDS { return }
	radius: f32 = 18
	if tier == 2 { radius = 32 } else if tier >= 3 { radius = 54 }
	angle := f32(rl.GetRandomValue(0, 6283)) / 1000
	speed := f32(rl.GetRandomValue(42, 82)) + f32(3 - tier) * 22 + f32(game.wave) * 3
	component := Asteroid_Component{
		position = position,
		velocity = direction(angle) * speed,
		radius = radius,
		angle = f32(rl.GetRandomValue(0, 6283)) / 1000,
		spin = f32(rl.GetRandomValue(-75, 75)) / 100,
		tier = tier,
		seed = rl.GetRandomValue(1, 100000),
	}

	entity := ecs.create_entity(world)
	if !ecs.add(world, rune_registry, entity, component) { return }
	append(&game.asteroids, Asteroid_Instance{entity = entity, component = component})
}

remove_asteroid :: proc(game: ^Game, index: int) {
	ecs.destroy_entity(world, game.asteroids[index].entity)
	unordered_remove(&game.asteroids, index)
}

clear_asteroids :: proc(game: ^Game) {
	for asteroid in game.asteroids {
		ecs.destroy_entity(world, asteroid.entity)
	}
	clear(&game.asteroids)
}

spawn_wave :: proc(game: ^Game) {
	game.wave += 1
	count := min(game.spawner.starting_count + game.wave - 1, game.spawner.max_wave_count)
	for _ in 0 ..< count {
		position := random_edge_position(game)
		for length_squared(wrapped_delta(position, game.ship.position, f32(game.arena.width), f32(game.arena.height))) < 180 * 180 {
			position = random_edge_position(game)
		}
		spawn_asteroid(game, position, 3)
	}
}
