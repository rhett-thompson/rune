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
	game.thruster_audio, ok = ecs.find_entity_by_id(&world, "thruster_audio")
	if !ok {
		fmt.eprintln("Asteroids scene is missing the thruster_audio entity")
		return
	}
	game.destroy_audio, ok = ecs.find_entity_by_id(&world, "asteroid_destroy_audio")
	if !ok {
		fmt.eprintln("Asteroids scene is missing the asteroid_destroy_audio entity")
		return
	}
	game.laser_audio, ok = ecs.find_entity_by_id(&world, "laser_audio")
	if !ok {
		fmt.eprintln("Asteroids scene is missing the laser_audio entity")
		return
	}
	game.music_audio, ok = ecs.find_entity_by_id(&world, "music_audio")
	if !ok {
		fmt.eprintln("Asteroids scene is missing the music_audio entity")
		return
	}
	game.ship_explode_audio, ok = ecs.find_entity_by_id(&world, "ship_explode_audio")
	if !ok {
		fmt.eprintln("Asteroids scene is missing the ship_explode_audio entity")
		return
	}

	game.asteroids = make([dynamic]Asteroid_Instance)
	game.bullets = make([dynamic]Bullet)
	game.particles = make([dynamic]Particle)
	defer delete(game.asteroids)
	defer delete(game.bullets)
	defer delete(game.particles)
	reset_game(&game)
	if !rune.register_system(&engine, {
		name = "asteroids",
		update = update_game,
		draw = draw_game,
	}) {
		fmt.eprintln("Could not register Asteroids system")
		return
	}
	rune.run_scene(&engine, &world)
}
