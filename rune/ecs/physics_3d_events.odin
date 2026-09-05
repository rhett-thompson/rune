package ecs

import b3 "vendor:box3d"

// Copy native event arrays before gameplay can invalidate them.
collect_box3d_events :: proc(world: ^World) {
	state := &world.physics_3d
	contacts := b3.World_GetContactEvents(world.box3d_world)
	for event in contacts.endEvents[:contacts.endCount] {
		physics_pair_event(
			state,
			b3.StoreShapeId(event.shapeIdA),
			b3.StoreShapeId(event.shapeIdB),
			false,
			.End,
		)
	}
	for event in contacts.beginEvents[:contacts.beginCount] {
		physics_pair_event(
			state,
			b3.StoreShapeId(event.shapeIdA),
			b3.StoreShapeId(event.shapeIdB),
			false,
			.Begin,
		)
	}
	sensors := b3.World_GetSensorEvents(world.box3d_world)
	for event in sensors.endEvents[:sensors.endCount] {
		physics_pair_event(
			state,
			b3.StoreShapeId(event.sensorShapeId),
			b3.StoreShapeId(event.visitorShapeId),
			true,
			.End,
		)
	}
	for event in sensors.beginEvents[:sensors.beginCount] {
		physics_pair_event(
			state,
			b3.StoreShapeId(event.sensorShapeId),
			b3.StoreShapeId(event.visitorShapeId),
			true,
			.Begin,
		)
	}
}

physics_3d_entity_from_shape :: proc(world: ^World, shape: b3.ShapeId) -> (Physics_Shape, bool) {
	if !b3.Shape_IsValid(shape) {return {}, false}
	result, found := world.physics_3d.shapes[b3.StoreShapeId(shape)]
	return result, found && is_alive(world, result.entity)
}
