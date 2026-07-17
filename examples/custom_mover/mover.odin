package main

import "rune:ecs"

Mover :: struct {
	speed: f32,
}

// mover_system is game code. Mover stays declarative JSON data, while this Odin
// system gives it behaviour by updating the entity's typed Transform component.
mover_system :: proc(world: ^ecs.World, entity: ecs.Entity, move_x: f32, dt: f32) {
	mover, has_mover := ecs.get(world, entity, Mover)
	if !has_mover {
		return
	}
	transform, has_transform := ecs.get(world, entity, ecs.Transform)
	if !has_transform {
		return
	}

	transform.position[0] += mover.speed * move_x * dt
	if transform.position[0] > 760 {
		transform.position[0] = 40
	}

	ecs.set(world, entity, transform)

}
