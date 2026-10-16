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
	// A visual leaf cannot change native collision. Visit descendants so a
	// collision-free group still suspends and restores the bodies below it.
	has_2d:=activation_has_physics_2d(world,entity)
	has_3d:=activation_has_physics_3d(world,entity)
	if has_2d || has_3d {
		enabled:=is_enabled(world,entity)
		if has_2d {
			if enabled {world.physics_2d.needs_sync=true}
			else {physics_2d_remove_entity(world,entity)}
		}
		if has_3d {
			if enabled {world.physics_3d.needs_sync=true}
			else {physics_3d_remove_entity(world,entity)}
		}
	}
	for child in child_entities(world, entity) {refresh_activation(world, child)}
}

@(private)
activation_has_physics_2d :: proc(world: ^World, entity: Entity) -> bool {
	if _,found:=world.box2d_bodies[entity]; found {return true}
	if _,found:=world.rigid_bodies_2d[entity]; found {return true}
	if _,found:=world.box_colliders_2d[entity]; found {return true}
	if _,found:=world.circle_colliders_2d[entity]; found {return true}
	if _,found:=world.capsule_colliders_2d[entity]; found {return true}
	if _,found:=world.polygon_colliders_2d[entity]; found {return true}
	if _,found:=world.segment_colliders_2d[entity]; found {return true}
	if _,found:=world.character_controllers_2d[entity]; found {return true}
	return false
}

@(private)
activation_has_physics_3d :: proc(world: ^World, entity: Entity) -> bool {
	if _,found:=world.box3d_bodies[entity]; found {return true}
	if _,found:=world.rigid_bodies_3d[entity]; found {return true}
	if _,found:=world.box_colliders[entity]; found {return true}
	if _,found:=world.sphere_colliders[entity]; found {return true}
	if _,found:=world.character_controllers_3d[entity]; found {return true}
	if terrain,found:=world.terrains[entity]; found && terrain.collision {return true}
	if mesh,found:=world.static_meshes[entity]; found && mesh.mesh!=nil {return true}
	return false
}
