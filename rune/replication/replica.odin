package replication

import "rune:ecs"

IDENTITY_COMPONENT :: "ReplicationIdentity"

register :: proc(registry: ^ecs.Component_Registry) -> bool {
	return ecs.register_component(registry, IDENTITY_COMPONENT, Identity, Identity{}, "Host-assigned network entity ID and owning relay peer")
}

// A Replica owns only entities it creates. Keeping the full generation-bearing
// handle and expected Identity prevents stale records from adopting unrelated
// entities after World replacement or application edits.
Replica :: struct {
	entities:    [MAX_ENTITIES]ecs.Entity,
	ids:         [MAX_ENTITIES]u32,
	owner_peers: [MAX_ENTITIES]u32,
	count:       int,
	last_tick:   u32,
	has_tick:    bool,
}

entity_for_id :: proc(replica: ^Replica, id: u32) -> (ecs.Entity, bool) {
	if replica == nil || id == 0 || replica.count < 0 || replica.count > MAX_ENTITIES {return ecs.Entity(0), false}
	for index in 0 ..< replica.count {
		if replica.ids[index] == id {return replica.entities[index], true}
	}
	return ecs.Entity(0), false
}

@(private)
owns_entity :: proc(replica: ^Replica, world: ^ecs.World, index: int) -> bool {
	entity := replica.entities[index]
	if !ecs.is_alive(world, entity) {return false}
	identity, found := ecs.get(world, entity, Identity)
	return found && identity.id == replica.ids[index] && identity.owner_peer == replica.owner_peers[index]
}

// Replica destruction preserves children attached by game code. Those children
// are application-owned and must never be recursively removed with a player.
@(private)
destroy_owned_entity :: proc(world: ^ecs.World, entity: ecs.Entity) {
	// Reparenting rebuilds ECS hierarchy indexes. Copy their borrowed child
	// slice before the first edit so subsequent children remain valid to read.
	children := ecs.child_entities(world, entity)
	owned_children := make([]ecs.Entity, len(children), context.temp_allocator)
	copy(owned_children, children)
	for child in owned_children {_ = ecs.set_parent(world, child, ecs.Entity(0))}
	_ = ecs.destroy_entity(world, entity, recursive = false)
}

clear :: proc(replica: ^Replica, world: ^ecs.World) {
	if replica == nil {return}
	if world != nil && replica.count >= 0 && replica.count <= MAX_ENTITIES {
		for index in 0 ..< replica.count {
			if owns_entity(replica, world, index) {destroy_owned_entity(world, replica.entities[index])}
		}
	}
	replica^ = {}
}

// Validate the entire snapshot before touching the World. New entities are
// prepared first, so missing registration or failed creation cannot partially
// update existing players. Stale/invalid snapshots leave both objects intact.
apply_snapshot :: proc(replica: ^Replica, world: ^ecs.World, registry: ^ecs.Component_Registry, value: Snapshot) -> bool {
	value := value
	if replica == nil || world == nil || registry == nil || !snapshot_valid(value) ||
	   replica.count < 0 || replica.count > MAX_ENTITIES ||
	   (replica.has_tick && !sequence_newer(value.tick, replica.last_tick)) {return false}
	identity_descriptor, registered := ecs.component_descriptor(registry, IDENTITY_COMPONENT)
	transform_name, transform_registered := ecs.component_name_for_type(registry, ecs.Transform)
	if !registered || identity_descriptor.type_id != typeid_of(Identity) || identity_descriptor.create_typed == nil ||
	   !identity_descriptor.copy_value || !transform_registered {return false}
	transform_descriptor, _ := ecs.component_descriptor(registry, transform_name)
	if transform_descriptor.type_id != typeid_of(ecs.Transform) || transform_descriptor.allow_multiple {return false}

	next := Replica{count = value.count, last_tick = value.tick, has_tick = true}
	retained: [MAX_ENTITIES]bool
	created: [MAX_ENTITIES]bool
	transforms: [MAX_ENTITIES]ecs.Transform
	for state, index in value.states[:value.count] {
		next.ids[index] = state.id
		next.owner_peers[index] = state.owner_peer
		for previous in 0 ..< replica.count {
			if replica.ids[previous] != state.id || !owns_entity(replica, world, previous) {continue}
			transform, found := ecs.get(world, replica.entities[previous], ecs.Transform)
			if !found || !ecs.component_value_valid(transform) {return false}
			next.entities[index] = replica.entities[previous]
			transforms[index] = transform
			retained[previous] = true
			break
		}
		if next.entities[index] == ecs.Entity(0) {transforms[index] = ecs.default_transform()}
		transforms[index].position = {state.position[0], state.position[1], 0}
	}

	creation_ok := true
	for state, index in value.states[:value.count] {
		if next.entities[index] != ecs.Entity(0) {continue}
		entity := ecs.create_entity(world)
		if entity == ecs.Entity(0) {creation_ok = false; break}
		next.entities[index] = entity
		created[index] = true
		if !ecs.add(world, registry, entity, Identity{state.id, state.owner_peer}) ||
		   !ecs.add(world, registry, entity, transforms[index]) {creation_ok = false; break}
	}
	if !creation_ok {
		for index in 0 ..< value.count {if created[index] {destroy_owned_entity(world, next.entities[index])}}
		return false
	}
	for state, index in value.states[:value.count] {
		if created[index] {continue}
		// Both registered fixed-size components were verified above. Their typed
		// setters do not allocate and cannot fail for these validated values.
		identity_updated := ecs.set(world, next.entities[index], Identity{state.id, state.owner_peer})
		transform_updated := ecs.set(world, next.entities[index], transforms[index])
		assert(identity_updated && transform_updated)
	}
	for previous in 0 ..< replica.count {
		if !retained[previous] && owns_entity(replica, world, previous) {destroy_owned_entity(world, replica.entities[previous])}
	}
	replica^ = next
	return true
}

// Disabled replicated entities remain represented. Sorting by network ID makes
// snapshots deterministic even though ECS storage is backed by maps.
snapshot_from_world :: proc(world: ^ecs.World, tick: u32) -> (value: Snapshot, valid: bool) {
	if world == nil {return {}, false}
	value.tick = tick
	for entity in ecs.query2(world, Identity, ecs.Transform, include_disabled = true) {
		if value.count == MAX_ENTITIES {return {}, false}
		identity, identity_found := ecs.get(world, entity, Identity)
		transform, transform_found := ecs.get(world, entity, ecs.Transform)
		if !ecs.is_alive(world, entity) || !identity_found || !transform_found {return {}, false}
		state := State{identity.id, identity.owner_peer, {transform.position[0], transform.position[1]}}
		index := value.count
		for index > 0 && value.states[index-1].id > state.id {
			value.states[index] = value.states[index-1]
			index -= 1
		}
		value.states[index] = state
		value.count += 1
	}
	if !snapshot_valid(value) {return {}, false}
	return value, true
}
