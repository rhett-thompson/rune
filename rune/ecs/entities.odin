package ecs

create_entity :: proc(world: ^World) -> Entity {
	if world.next_entity == 0 {
		return Entity(0)
	}
	entity := make_entity(world.generation, world.next_entity)
	world.next_entity += 1
	world.entity_count += 1
	world.entities[entity] = true
	world.hierarchy_dirty = true
	// Every entity starts in the Default layer (bit 0).
	world.layer_masks[entity] = Default_Layer_Mask
	return entity
}

// destroy_entity is Rune's equivalent of Unity Destroy or Godot queue_free.
// Children are destroyed by default, and every component/native subsystem is
// detached before the runtime handle becomes invalid.
destroy_entity :: proc(world: ^World, entity: Entity, recursive := true) -> bool {
	if !is_alive(world, entity) {return false}
	children := child_entities(world, entity)
	if len(children) > 0 && !recursive {return false}
	child_copy := make([]Entity, len(children), context.temp_allocator)
	copy(child_copy, children)
	for child in child_copy {
		if !destroy_entity(world, child, true) {return false}
	}

	component_names := make([dynamic]string, context.temp_allocator)
	for name, components in world.component_data {
		if _, found := components[entity]; found {append(&component_names, name)}
	}
	for name in component_names {_ = remove_component(world, entity, name)}
	physics_2d_remove_entity(world, entity)
	physics_3d_remove_entity(world, entity)

	if id, found := world.entity_ids[entity]; found && id != "" {
		delete_key(&world.entities_by_id, id)
	}
	delete_key(&world.entity_ids, entity)
	delete_key(&world.entity_names, entity)
	delete_key(&world.entity_tags, entity)
	delete_key(&world.layer_masks, entity)
	delete_key(&world.parents, entity)
	delete_key(&world.entities, entity)
	world.entity_count -= 1
	world.hierarchy_dirty = true
	return true
}

make_entity :: proc(generation, index: u32) -> Entity {
	return Entity((u64(generation) << 32) | u64(index))
}

entity_index :: proc(entity: Entity) -> u32 {
	return u32(u64(entity) & 0xffffffff)
}

entity_generation :: proc(entity: Entity) -> u32 {
	return u32(u64(entity) >> 32)
}

is_alive :: proc(world: ^World, entity: Entity) -> bool {
	return(
		entity != Entity(0) &&
		entity_generation(entity) == world.generation &&
		world.entities[entity] \
	)
}

record_component_change :: proc(
	world: ^World,
	entity: Entity,
	name: string,
	kind: Component_Change_Kind,
) {
	owned_name := retain_scene_string(world, name)
	world.component_change_version += 1
	if world.component_change_version == 0 {world.component_change_version = 1}
	world.component_changes[Component_Change_Key{entity = entity, name = owned_name}] =
		Component_Change {
			entity  = entity,
			kind    = kind,
			version = world.component_change_version,
		}
}

// set_entity_metadata assigns scene-owned identity and filtering data. Non-empty
// IDs must be unique within a World so game code can resolve and cache an Entity
// handle. Names and tags may be empty or duplicated. A zero layer mask is not
// valid because it would make an entity invisible to every layer-filtered system.
set_entity_metadata :: proc(
	world: ^World,
	entity: Entity,
	id, name, tag: string,
	layer_mask: u64,
) -> bool {
	if !is_alive(world, entity) || layer_mask == 0 {
		return false
	}
	owned_id := retain_scene_string(world, id)
	owned_name := retain_scene_string(world, name)
	owned_tag := retain_scene_string(world, tag)
	if owned_id != "" {
		if existing, found := world.entities_by_id[owned_id]; found && existing != entity {
			return false
		}
		world.entities_by_id[owned_id] = entity
	}
	world.entity_ids[entity] = owned_id
	world.entity_names[entity] = owned_name
	world.entity_tags[entity] = owned_tag
	set_entity_layer_mask(world, entity, layer_mask)
	return true
}

entity_id :: proc(world: ^World, entity: Entity) -> (string, bool) {
	value, found := world.entity_ids[entity]
	return value, found
}

// find_entity_by_id resolves a non-empty scene ID to its World-local runtime
// handle. Cache the returned Entity in game code and resolve it again after a
// scene reload, because handles are only valid for their originating World.
find_entity_by_id :: proc(world: ^World, id: string) -> (Entity, bool) {
	if id == "" {
		return Entity(0), false
	}
	entity, found := world.entities_by_id[id]
	return entity, found
}

// entity_ref returns a persistent, JSON-facing reference for a scene entity.
// Unlike Entity, this value can be resolved again after the World is replaced.
// Runtime-only entities without an ID cannot produce a persistent reference.
entity_ref :: proc(world: ^World, entity: Entity) -> (Entity_Ref, bool) {
	id, found := entity_id(world, entity)
	if !found || id == "" {
		return {}, false
	}
	return Entity_Ref{id = id}, true
}

entity_ref_from_id :: proc(id: string) -> (Entity_Ref, bool) {
	if id == "" {
		return {}, false
	}
	return Entity_Ref{id = id}, true
}

resolve_entity_ref :: proc(world: ^World, ref: Entity_Ref) -> (Entity, bool) {
	return find_entity_by_id(world, ref.id)
}

entity_name :: proc(world: ^World, entity: Entity) -> (string, bool) {
	value, found := world.entity_names[entity]
	return value, found
}

entity_tag :: proc(world: ^World, entity: Entity) -> (string, bool) {
	value, found := world.entity_tags[entity]
	return value, found
}

set_entity_tag :: proc(world: ^World, entity: Entity, tag: string) -> bool {
	if !is_alive(world, entity) {return false}
	world.entity_tags[entity] = retain_scene_string(world, tag)
	return true
}

entity_layer_mask :: proc(world: ^World, entity: Entity) -> (u64, bool) {
	value, found := world.layer_masks[entity]
	return value, found
}

set_entity_layer_mask :: proc(world: ^World, entity: Entity, layer_mask: u64) -> bool {
	if !is_alive(world, entity) || layer_mask == 0 {return false}
	if world.layer_masks[entity] == layer_mask {return true}
	physics_2d_remove_entity(world, entity)
	physics_3d_remove_entity(world, entity)
	world.layer_masks[entity] = layer_mask
	return true
}

has_tag :: proc(world: ^World, entity: Entity, tag: string) -> bool {
	entity_tag, found := entity_tag(world, entity)
	return found && entity_tag == tag
}

is_in_layer_mask :: proc(world: ^World, entity: Entity, layer_mask: u64) -> bool {
	entity_mask, found := entity_layer_mask(world, entity)
	return found && (entity_mask & layer_mask) != 0
}
