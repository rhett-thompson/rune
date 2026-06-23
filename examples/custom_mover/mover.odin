package main

import "core:encoding/json"
import "rune:ecs"
import "rune:jsonutil"

// mover_system is game code. Mover stays declarative JSON data, while this Odin
// system gives it behaviour by updating the entity's typed Transform component.
mover_system :: proc(world: ^ecs.World, entity: ecs.Entity, move_x: f32, dt: f32) {

	mover_data, has_mover := ecs.get_component(world, entity, "Mover")
	if !has_mover {
		return
	}

	mover, mover_ok := mover_data.(json.Object)
	if !mover_ok {
		return
	}
	
	speed_data, has_speed := mover["speed"]
	if !has_speed {
		return
	}

	speed, speed_ok := jsonutil.number(speed_data)
	transform, has_transform := ecs.get_transform(world, entity)
	if !speed_ok || !has_transform {
		return
	}

	transform.position[0] += speed * move_x * dt
	if transform.position[0] > 760 {
		transform.position[0] = 40
	}

	ecs.set_transform(world, entity, transform)

}
