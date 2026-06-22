package ecs

import "core:encoding/json"

Entity :: distinct u64

World :: struct {
	next_entity:     Entity,
	entity_count:    int,
	entities:        map[Entity]bool,
	parents:         map[Entity]Entity,
	component_data:  map[string]map[Entity]json.Value,
	transforms:       map[Entity]Transform,
	sprite_renderers: map[Entity]SpriteRenderer,
	mesh_renderers:   map[Entity]MeshRenderer,
	sphere_renderers: map[Entity]SphereRenderer,
	orbits:           map[Entity]Orbit,
	rotators:         map[Entity]Rotator,
}

init :: proc() -> World {
	return World{
		next_entity = Entity(1),
		entities = make(map[Entity]bool),
		parents = make(map[Entity]Entity),
		component_data = make(map[string]map[Entity]json.Value),
		transforms = make(map[Entity]Transform),
		sprite_renderers = make(map[Entity]SpriteRenderer),
		mesh_renderers = make(map[Entity]MeshRenderer),
		sphere_renderers = make(map[Entity]SphereRenderer),
		orbits = make(map[Entity]Orbit),
		rotators = make(map[Entity]Rotator),
	}
}

// set_parent makes child inherit its parent's scene transform. Passing Entity(0)
// makes the entity a scene root.
set_parent :: proc(world: ^World, child, parent: Entity) -> bool {
	if !is_alive(world, child) || (parent != Entity(0) && !is_alive(world, parent)) || child == parent {
		return false
	}
	if parent == Entity(0) {
		delete_key(&world.parents, child)
	} else {
		world.parents[child] = parent
	}
	return true
}

get_parent :: proc(world: ^World, entity: Entity) -> (Entity, bool) {
	parent, found := world.parents[entity]
	return parent, found
}

// root_entities and child_entities expose the scene hierarchy to render systems
// without allowing them to mutate World storage.
root_entities :: proc(world: ^World) -> []Entity {
	result := make([dynamic]Entity, context.temp_allocator)
	for entity in world.entities {
		if _, has_parent := world.parents[entity]; !has_parent {
			append(&result, entity)
		}
	}
	return result[:]
}

child_entities :: proc(world: ^World, parent: Entity) -> []Entity {
	result := make([dynamic]Entity, context.temp_allocator)
	for entity, entity_parent in world.parents {
		if entity_parent == parent {
			append(&result, entity)
		}
	}
	return result[:]
}

create_entity :: proc(world: ^World) -> Entity {
	entity := world.next_entity
	world.next_entity += 1
	world.entity_count += 1
	world.entities[entity] = true
	return entity
}

is_alive :: proc(world: ^World, entity: Entity) -> bool {
	return world.entities[entity]
}

// add_component attaches JSON data to an entity. Components must be explicitly
// registered so misspelled or unsupported component names fail at load time.
add_component :: proc(world: ^World, registry: ^Component_Registry, entity: Entity, name: string, data: json.Value) -> bool {
	if !is_alive(world, entity) || !has_component(registry, name) {
		return false
	}

	transform: Transform
	sprite_renderer: SpriteRenderer
	mesh_renderer: MeshRenderer
	sphere_renderer: SphereRenderer
	orbit: Orbit
	rotator: Rotator
	parse_ok: bool
	if name == "Transform" {
		transform, parse_ok = transform_from_json(data)
		if !parse_ok {
			return false
		}
	}
	if name == "SpriteRenderer" { sprite_renderer, parse_ok = sprite_renderer_from_json(data); if !parse_ok { return false } }
	if name == "MeshRenderer" { mesh_renderer, parse_ok = mesh_renderer_from_json(data); if !parse_ok { return false } }
	if name == "SphereRenderer" { sphere_renderer, parse_ok = sphere_renderer_from_json(data); if !parse_ok { return false } }
	if name == "Orbit" { orbit, parse_ok = orbit_from_json(data); if !parse_ok { return false } }
	if name == "Rotator" { rotator, parse_ok = rotator_from_json(data); if !parse_ok { return false } }

	components, component_type_found := world.component_data[name]
	if !component_type_found {
		components = make(map[Entity]json.Value)
	}
	components[entity] = data
	world.component_data[name] = components

	if name == "Transform" {
		world.transforms[entity] = transform
	}
	if name == "SpriteRenderer" { world.sprite_renderers[entity] = sprite_renderer }
	if name == "MeshRenderer" { world.mesh_renderers[entity] = mesh_renderer }
	if name == "SphereRenderer" { world.sphere_renderers[entity] = sphere_renderer }
	if name == "Orbit" { world.orbits[entity] = orbit }
	if name == "Rotator" { world.rotators[entity] = rotator }
	return true
}

remove_component :: proc(world: ^World, entity: Entity, name: string) -> bool {
	components, found := world.component_data[name]
	if !found {
		return false
	}
	_, component_found := components[entity]
	if !component_found {
		return false
	}

	delete_key(&components, entity)
	world.component_data[name] = components
	if name == "Transform" {
		delete_key(&world.transforms, entity)
	}
	if name == "SpriteRenderer" { delete_key(&world.sprite_renderers, entity) }
	if name == "MeshRenderer" { delete_key(&world.mesh_renderers, entity) }
	if name == "SphereRenderer" { delete_key(&world.sphere_renderers, entity) }
	if name == "Orbit" { delete_key(&world.orbits, entity) }
	if name == "Rotator" { delete_key(&world.rotators, entity) }
	return true
}

has_component_data :: proc(world: ^World, entity: Entity, name: string) -> bool {
	components, found := world.component_data[name]
	if !found {
		return false
	}
	_, component_found := components[entity]
	return component_found
}

get_component :: proc(world: ^World, entity: Entity, name: string) -> (json.Value, bool) {
	components, found := world.component_data[name]
	if !found {
		return {}, false
	}

	component, component_found := components[entity]
	return component, component_found
}

// get_transform gives game systems typed Transform data for an entity. Call
// set_transform after changing the returned value.
get_transform :: proc(world: ^World, entity: Entity) -> (Transform, bool) {
	transform, found := world.transforms[entity]
	return transform, found
}

set_transform :: proc(world: ^World, entity: Entity, transform: Transform) -> bool {
	if !is_alive(world, entity) || !has_component_data(world, entity, "Transform") {
		return false
	}

	world.transforms[entity] = transform
	return true
}

get_sprite_renderer :: proc(world: ^World, entity: Entity) -> (SpriteRenderer, bool) { value, found := world.sprite_renderers[entity]; return value, found }
set_sprite_renderer :: proc(world: ^World, entity: Entity, value: SpriteRenderer) -> bool { if !has_component_data(world, entity, "SpriteRenderer") { return false }; world.sprite_renderers[entity] = value; return true }
get_mesh_renderer :: proc(world: ^World, entity: Entity) -> (MeshRenderer, bool) { value, found := world.mesh_renderers[entity]; return value, found }
set_mesh_renderer :: proc(world: ^World, entity: Entity, value: MeshRenderer) -> bool { if !has_component_data(world, entity, "MeshRenderer") { return false }; world.mesh_renderers[entity] = value; return true }
get_sphere_renderer :: proc(world: ^World, entity: Entity) -> (SphereRenderer, bool) { value, found := world.sphere_renderers[entity]; return value, found }
set_sphere_renderer :: proc(world: ^World, entity: Entity, value: SphereRenderer) -> bool { if !has_component_data(world, entity, "SphereRenderer") { return false }; world.sphere_renderers[entity] = value; return true }
get_orbit :: proc(world: ^World, entity: Entity) -> (Orbit, bool) { value, found := world.orbits[entity]; return value, found }
set_orbit :: proc(world: ^World, entity: Entity, value: Orbit) -> bool { if !has_component_data(world, entity, "Orbit") { return false }; world.orbits[entity] = value; return true }
get_rotator :: proc(world: ^World, entity: Entity) -> (Rotator, bool) { value, found := world.rotators[entity]; return value, found }
set_rotator :: proc(world: ^World, entity: Entity, value: Rotator) -> bool { if !has_component_data(world, entity, "Rotator") { return false }; world.rotators[entity] = value; return true }
