package ecs

import b2 "vendor:box2d"

// Copy native event arrays before gameplay can invalidate them.
collect_box2d_events :: proc(world: ^World) {
	state := &world.physics_2d
	contacts := b2.World_GetContactEvents(world.box2d_world)
	for event in contacts.endEvents[:contacts.endCount] {
		physics_pair_event(
			state,
			transmute(u64)event.shapeIdA,
			transmute(u64)event.shapeIdB,
			false,
			.End,
		)
	}
	for event in contacts.beginEvents[:contacts.beginCount] {
		if world.one_way_shapes_2d[transmute(u64)event.shapeIdA].one_way || world.one_way_shapes_2d[transmute(u64)event.shapeIdB].one_way {continue}
		physics_pair_event(
			state,
			transmute(u64)event.shapeIdA,
			transmute(u64)event.shapeIdB,
			false,
			.Begin,
		)
	}
	// One-way contact lifetime follows admitted solver contacts. Geometric
	// underside overlaps must not produce collision Begin events.
	for pair in state.pairs {
		if pair.is_sensor {continue}
		if !world.one_way_shapes_2d[pair.a].one_way && !world.one_way_shapes_2d[pair.b].one_way {continue}
		if !world.one_way_contacts_2d[pair] {physics_pair_event(state,pair.a,pair.b,false,.End)}
	}
	for pair in world.one_way_contacts_2d {physics_pair_event(state,pair.a,pair.b,false,.Begin)}
	sensors := b2.World_GetSensorEvents(world.box2d_world)
	for event in sensors.endEvents[:sensors.endCount] {
		physics_pair_event(
			state,
			transmute(u64)event.sensorShapeId,
			transmute(u64)event.visitorShapeId,
			true,
			.End,
		)
	}
	for event in sensors.beginEvents[:sensors.beginCount] {
		physics_pair_event(
			state,
			transmute(u64)event.sensorShapeId,
			transmute(u64)event.visitorShapeId,
			true,
			.Begin,
		)
	}
}

physics_2d_entity_from_shape :: proc(world: ^World, shape: b2.ShapeId) -> (Physics_Shape, bool) {
	if !b2.Shape_IsValid(shape) {return {}, false}
	result, found := world.physics_2d.shapes[transmute(u64)shape]
	return result, found && is_alive(world, result.entity)
}

physics_2d_native_body :: proc(world: ^World, entity: Entity) -> (b2.BodyId, bool) {
	body, found := world.box2d_bodies[entity]
	return body, found && b2.Body_IsValid(body)
}
