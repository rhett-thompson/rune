package main

import "core:encoding/json"
import "engine:ecs"

// mover_system is game code. Mover stays declarative JSON data, while this Odin
// system gives it behaviour by updating the entity's typed Transform component.
mover_system :: proc(world: ^ecs.World, entity: ecs.Entity, dt: f32) {
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

	speed, speed_ok := json_number(speed_data)
	transform, has_transform := ecs.get_transform(world, entity)
	if !speed_ok || !has_transform {
		return
	}

	transform.position[0] += speed * dt
	if transform.position[0] > 760 {
		transform.position[0] = 40
	}
	ecs.set_transform(world, entity, transform)
}

json_number :: proc(value: json.Value) -> (f32, bool) {
	#partial switch number in value {
	case json.Integer: return f32(number), true
	case json.Float:   return f32(number), true
	}
	return 0, false
}
