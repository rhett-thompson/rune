package main

import "rune:ecs"
import rl "vendor:raylib"

Arena_Config :: struct {
	width, height:                         i32,
	star_count:                            i32,
	line_color, accent_color, muted_color: [4]u8,
}

Ship_Config :: struct {
	position:                                    rl.Vector2,
	radius, thrust, turn_speed, drag, max_speed: f32,
	bullet_speed, bullet_life, fire_delay:       f32,
}

Asteroid_Spawner :: struct {
	starting_lives, starting_count, max_wave_count: i32,
	respawn_delay, invulnerable_time:               f32,
}

Asteroid_Component :: struct {
	position, velocity:  rl.Vector2,
	radius, angle, spin: f32,
	tier, seed:          i32,
}

Asteroid_Instance :: struct {
	entity:    ecs.Entity,
	component: Asteroid_Component,
}
