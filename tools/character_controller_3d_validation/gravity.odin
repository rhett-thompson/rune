package main

import "core:fmt"
import "core:math"
import "rune:ecs"

validate_gravity_frames :: proc(r:^ecs.Component_Registry) {
	// Rotate the same floor/wall/ceiling setup onto its side and upside down.
	for up in ([3][3]f32{{1,0,0},{0,-1,0},{0,0,1}}) {
		w:=ecs.init()
		size:=[3]f32{100,100,100}
		for axis in 0..<3 {if up[axis]!=0 {size[axis]=1}}
		box(&w,r,-up*0.5,size)
		e:=player(&w,r,up*2)
		assert(ecs.character_controller_3d_move_on_plane(&w,e,{},up))
		step(&w,120)
		assert(state(&w,e).grounded,"arbitrary-up floor contact")
		vertical:=ecs.character_dot_3d(pose(&w,e).position,up)
		assert(math.abs(vertical)<0.03,"feet stay on rotated floor")
		ecs.character_controller_3d_jump(&w,e);step(&w)
		assert(ecs.character_dot_3d(state(&w,e).velocity,up)>7,"jump against local gravity")
		ecs.character_controller_3d_release_jump(&w,e);step(&w)
		assert(ecs.character_dot_3d(state(&w,e).velocity,up)<4,"local jump cut")
		step(&w,150);assert(state(&w,e).grounded,"land in rotated frame")
		direction:=[3]f32{0,1,0};if up[1]!=0 {direction={1,0,0}}
		// Input parallel to up is discarded, preserving analog tangent strength.
		assert(ecs.character_controller_3d_move_on_plane(&w,e,direction*0.5+up*3,up*2))
		step(&w,60)
		assert(ecs.character_dot_3d(pose(&w,e).position,direction)>1.8,"tangent movement")
		assert(state(&w,e).grounded,"grounded while moving sideways/upside down")
		feet:=pose(&w,e).position
		assert(ecs.trigger_overlaps_character_3d(&w,e,{shape=.sphere},feet+up*1.5,{},0.1),"trigger at tilted capsule head")
		assert(ecs.trigger_overlaps_character_3d(&w,e,{shape=.box},feet+up*1.5,{0.1,0.1,0.1},1),"box trigger at tilted capsule head")
		assert(!ecs.trigger_overlaps_character_3d(&w,e,{shape=.sphere},feet-up,{},0.1),"trigger below feet misses")
		assert(!ecs.trigger_overlaps_character_3d(&w,e,{shape=.box},feet+direction*1.5,{0.1,0.1,0.1},1),"box beside tilted capsule misses")
		assert(!ecs.character_controller_3d_move_on_plane(&w,e,{},{}),"reject zero up")
		ecs.destroy(&w)
	}
	fmt.println("PASS sideways/upside-down gravity, tangent input, jump cut, and landing")
}
