package main

import "core:math"
import "rune:ecs"

// Example gameplay data. The engine does not require a platform/path component.
PlatformMotion :: struct {
	axis: int,
	minimum, maximum: f32,
	speed: f32,
}

move_platforms :: proc(world:^ecs.World, dt:f32) {
	if dt<=0 {return}
	for entity in ecs.query(world,PlatformMotion) {
		motion,_:=ecs.get(world,entity,PlatformMotion)
		pose,has_pose:=ecs.get_transform(world,entity)
		body,has_body:=ecs.get_rigid_body_2d(world,entity)
		if !has_pose || !has_body || body.body_type!="kinematic" {continue}
		if motion.axis<0 || motion.axis>1 || !ecs.finite_nonnegative(motion.speed) ||
			!ecs.physics_query_vector_valid([2]f32{motion.minimum,motion.maximum}) || motion.minimum>=motion.maximum {
			body.velocity={};ecs.set_rigid_body_2d(world,entity,body);continue
		}
		position:=pose.position[motion.axis]
		direction:f32=1
		if body.velocity[motion.axis]<0 {direction=-1}
		if position>=motion.maximum-0.001 {direction=-1}
		if position<=motion.minimum+0.001 {direction=1}
		target:=motion.maximum if direction>0 else motion.minimum
		body.velocity={}
		body.velocity[motion.axis]=direction*min(motion.speed,math.abs(target-position)/dt)
		// Move through physics rather than setting Transform; riders share velocity
		// and the last partial step reaches each endpoint without a teleport.
		ecs.set_rigid_body_2d(world,entity,body)
	}
}
