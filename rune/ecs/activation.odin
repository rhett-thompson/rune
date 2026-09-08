package ecs

// Local setting, independent of ancestors. Missing entries mean enabled.
is_locally_enabled :: proc(world: ^World, entity: Entity) -> bool {
	return is_alive(world, entity) && !world.disabled_entities[entity]
}

// Effective setting. A disabled parent suspends its entire subtree without
// overwriting any child's local setting.
is_enabled :: proc(world: ^World, entity: Entity) -> bool {
	if !is_alive(world, entity) {return false}
	for current := entity; current != Entity(0); current = world.parents[current] {
		if world.disabled_entities[current] {return false}
	}
	return true
}

set_enabled :: proc(world: ^World, entity: Entity, enabled: bool) -> bool {
	if !is_alive(world, entity) {return false}
	if is_locally_enabled(world, entity) == enabled {return true}
	if enabled {delete_key(&world.disabled_entities, entity)} else {world.disabled_entities[entity] = true}
	refresh_activation(world, entity)
	return true
}

// Remove suspended bodies immediately, including for queries before the next
// simulation tick. Re-enabling recreates them from retained component state.
refresh_activation :: proc(world: ^World, entity: Entity) {
	world.physics_2d.needs_sync = true
	world.physics_3d.needs_sync = true
	if !is_enabled(world, entity) {
		physics_2d_remove_entity(world, entity)
		physics_3d_remove_entity(world, entity)
	}
	for child in child_entities(world, entity) {refresh_activation(world, child)}
}
