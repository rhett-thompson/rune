package main

import example_text "../shared/text"

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:pool"

world: ^ecs.World
game: Game
rune_registry: ^ecs.Component_Registry
asteroids_ready: bool

start_asteroids :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	world = scene_world
	config_ok :=
		component_into(world, &game.arena) &&
		component_into(world, &game.ship_config) &&
		component_into(world, &game.spawner)
	entity_ok: bool
	game.thruster_audio, entity_ok = ecs.find_entity_by_id(world, "thruster_audio"); config_ok = config_ok && entity_ok
	game.destroy_audio, entity_ok = ecs.find_entity_by_id(
		world,
		"asteroid_destroy_audio",
	); config_ok = config_ok && entity_ok
	game.laser_audio, entity_ok = ecs.find_entity_by_id(world, "laser_audio"); config_ok = config_ok && entity_ok
	game.music_audio, entity_ok = ecs.find_entity_by_id(world, "music_audio"); config_ok = config_ok && entity_ok
	game.ship_explode_audio, entity_ok = ecs.find_entity_by_id(
		world,
		"ship_explode_audio",
	); config_ok = config_ok && entity_ok
	if !config_ok { fmt.eprintln("Asteroids startup scene is missing required components or audio entities"); return }
	game.asteroids = make([dynamic]Asteroid_Instance)
	if !pool.init(&game.bullets, MAX_BULLETS, .Fixed) || !pool.init(&game.particles, 256, .Double) {
		fmt.eprintln("Could not allocate Asteroids bullet/particle pools")
		stop_asteroids(engine, scene_world)
		return
	}
	reset_game(&game)
	asteroids_ready = true
}

stop_asteroids :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	delete(game.asteroids)
	pool.destroy(&game.bullets)
	pool.destroy(&game.particles)
	game.asteroids = nil
	asteroids_ready = false
}

reload_asteroids :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	stop_asteroids(engine, scene_world)
	start_asteroids(engine, scene_world)
}

main :: proc() {
	engine, ok := rune.init("examples/asteroids/project.json")
	if !ok { fmt.eprintln("Could not load examples/asteroids/project.json"); return }
	defer rune.shutdown(&engine)
	if !example_text.init(&engine.assets) { fmt.eprintln("Could not load shared example font"); return }

	rune_registry = rune.component_registry(&engine)
	if !ecs.register_component(
		   rune_registry,
		   "AsteroidsArena",
		   Arena_Config,
		   Arena_Config{},
		   "Asteroids playfield presentation",
	   ) ||
	   !ecs.register_component(rune_registry, "AsteroidsShip", Ship_Config, Ship_Config{}, "Player ship tuning") ||
	   !ecs.register_component(
			   rune_registry,
			   "AsteroidSpawner",
			   Asteroid_Spawner,
			   Asteroid_Spawner{},
			   "Creates asteroid entities for each wave",
		   ) ||
	   !ecs.register_component(
			   rune_registry,
			   "Asteroid",
			   Asteroid_Component,
			   Asteroid_Component{},
			   "Runtime asteroid position, motion, size, and tier",
		   ) {
		fmt.eprintln("Could not register Asteroids components")
		return
	}

	if !rune.register_system(
		&engine,
		{
			name = "asteroids",
			start = start_asteroids,
			update = update_game,
			draw = draw_game,
			on_scene_reloaded = reload_asteroids,
			shutdown = stop_asteroids,
		},
	) {
		fmt.eprintln("Could not register Asteroids system")
		return
	}
	if !rune.run(&engine) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
