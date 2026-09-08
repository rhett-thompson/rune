package ecs

import "core:encoding/json"

// Authored duration stays separate from elapsed simulation time.
Lifetime :: struct {seconds: f32}

lifetime_from_json :: proc(data: json.Value) -> (Lifetime, bool) {
	object, ok := data.(json.Object)
	if !ok || len(object) != 1 {return {}, false}
	seconds, valid := read_number(object["seconds"])
	value := Lifetime{seconds}
	return value, valid && component_value_valid(value)
}

get_lifetime :: proc(world: ^World, entity: Entity) -> (Lifetime, bool) {
	value, found := world.lifetimes[entity]
	return value, found
}

set_lifetime :: proc(world: ^World, entity: Entity, value: Lifetime) -> bool {
	if !has_component_data(world, entity, "Lifetime") || !component_value_valid(value) {return false}
	commit_component_value(world, entity, "Lifetime", &world.lifetimes, value)
	return true
}

// Reset by setting Lifetime, even when the duration is unchanged.
update_lifetimes :: proc(world: ^World, dt: f32) {
	if !finite_nonnegative(dt) || dt == 0 {return}
	expired := make([dynamic]Entity, context.temp_allocator)
	for entity, lifetime in world.lifetimes {
		if !is_enabled(world, entity) {continue}
		elapsed := world.lifetime_elapsed[entity] + dt
		world.lifetime_elapsed[entity] = elapsed
		if elapsed >= lifetime.seconds {append(&expired, entity)}
	}
	// Destruction may remove children and their lifetimes; never mutate the
	// component map while iterating it.
	for entity in expired {destroy_entity(world, entity)}
}
