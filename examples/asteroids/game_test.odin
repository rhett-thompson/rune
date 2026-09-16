package main

import "core:testing"
import rune "rune:core"
import "rune:ecs"

@(test)
asteroids_use_live_components :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_component(&r, "Asteroid", Asteroid_Component, Asteroid_Component{}, "Asteroid"))
	world = &w; defer {world = nil}
	e := ecs.create_entity(&w)
	assert(ecs.add(&w, &r, e, Asteroid_Component{position = {20,30}, velocity = {10,0}, radius = 18}))
	g := Game{arena = {width = 800, height = 600}}
	engine: rune.Engine
	update_asteroids(&g, &engine, 0.5)
	value, _ := ecs.get(&w, e, Asteroid_Component)
	testing.expect(t, value.position.x == 25, "simulation writes back to ECS")
	value.velocity.x = 30; ecs.set(&w, e, value)
	update_asteroids(&g, &engine, 0.5)
	value, _ = ecs.get(&w, e, Asteroid_Component)
	testing.expect(t, value.position.x == 40, "runtime edits affect movement")
	ecs.set_enabled(&w, e, false)
	update_asteroids(&g, &engine, 1)
	value, _ = ecs.get(&w, e, Asteroid_Component)
	testing.expect(t, value.position.x == 40 && len(ecs.query(&w, Asteroid_Component)) == 0, "disabled asteroids stop participating")
	clear_asteroids(&g)
	testing.expect(t, !ecs.is_alive(&w, e), "reset also clears disabled asteroids")
}
