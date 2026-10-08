package main

import "core:fmt"
import "core:math"
import "rune:ecs"

validate_navigation_braking :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r)
	e:=player(&w,r)
	config:=ecs.default_character_controller_3d()
	config.move_speed=6;config.acceleration=6;config.braking=24
	assert(ecs.set(&w,e,config))
	step(&w,3)
	assert(state(&w,e).grounded)
	// Start from the same velocity to compare a one-step speed reduction.
	initial:=state(&w,e)
	initial.velocity={6,0,0}
	w.character_controller_states_3d[e]=initial
	assert(ecs.character_controller_3d_move(&w,e,{0.5,0}))
	step(&w)
	assert(math.abs(state(&w,e).velocity[0]-5.9)<0.001,
		"ordinary analog slowdown continues to use acceleration")
	w.character_controller_states_3d[e]=initial
	assert(ecs.character_controller_3d_move(&w,e,{0.5,0}))
	nav:=state(&w,e);nav.navigation_braking=true
	w.character_controller_states_3d[e]=nav
	step(&w)
	assert(math.abs(state(&w,e).velocity[0]-5.6)<0.001,
		"navigation nonzero slowdown uses motor braking")
	// Reversing direction is steering rather than slowing along the route.
	w.character_controller_states_3d[e]=initial
	assert(ecs.character_controller_3d_move(&w,e,{-0.5,0}))
	nav=state(&w,e);nav.navigation_braking=true
	w.character_controller_states_3d[e]=nav
	step(&w)
	assert(math.abs(state(&w,e).velocity[0]-5.9)<0.001,
		"navigation reversal retains motor acceleration")
	assert(ecs.character_controller_3d_move(&w,e,{0.5,0}))
	assert(!state(&w,e).navigation_braking,"ordinary move clears navigation braking override")
	nav=state(&w,e);nav.navigation_braking=true
	w.character_controller_states_3d[e]=nav
	assert(ecs.character_controller_3d_move_on_plane(&w,e,{0.5,0,0},{0,1,0}))
	assert(!state(&w,e).navigation_braking,"plane movement clears navigation braking override")
	// Zero input always uses braking, with or without navigation's override.
	w.character_controller_states_3d[e]=initial
	assert(ecs.character_controller_3d_move(&w,e,{}))
	step(&w)
	assert(math.abs(state(&w,e).velocity[0]-5.6)<0.001,
		"zero input keeps ordinary braking behavior")
	fmt.println("PASS navigation nonzero braking, player input, reversals, and override resets")
}
