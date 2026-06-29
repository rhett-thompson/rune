package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"

world: ecs.World
game: Game
rune_registry: ^ecs.Component_Registry

main :: proc() {
	engine, ok := rune.init("examples/asteroids/project.json")
	if !ok { fmt.eprintln("Could not load examples/asteroids/project.json"); return }
	defer rune.shutdown(&engine)

	rune_registry = rune.component_registry(&engine)
	if !ecs.register_component(rune_registry, {name = "AsteroidsArena", description = "Asteroids playfield presentation"}) ||
	   !ecs.register_component(rune_registry, {name = "AsteroidsShip", description = "Player ship tuning"}) ||
	   !ecs.register_component(rune_registry, {name = "AsteroidSpawner", description = "Creates asteroid entities for each wave"}) ||
	   !ecs.register_component(rune_registry, {name = "Asteroid", description = "Runtime asteroid position, motion, size, and tier"}) {
		fmt.eprintln("Could not register Asteroids components")
		return
	}

	scene_ok: bool
	world, scene_ok = rune.load_scene(&engine, "examples/asteroids/scenes/main.scene.json")
	if !scene_ok { fmt.eprintln("Could not load the Asteroids scene"); return }
	if !component_into(&world, "AsteroidsArena", &game.arena) ||
	   !component_into(&world, "AsteroidsShip", &game.ship_config) ||
	   !component_into(&world, "AsteroidSpawner", &game.spawner) {
		fmt.eprintln("Asteroids scene requires arena, ship, and asteroid spawner entities")
		return
	}

	game.asteroids = make([dynamic]Asteroid_Instance)
	game.bullets = make([dynamic]Bullet)
	game.particles = make([dynamic]Particle)
	defer delete(game.asteroids)
	defer delete(game.bullets)
	defer delete(game.particles)
	reset_game(&game)
	rune.run(&engine, update_game, draw_game)
}
