package scene

import "core:encoding/json"
import "core:os"
import "engine:ecs"

Entity_Data :: struct {
	id:         string,
	name:       string,
	components: map[string]json.Value,
	children:   []Entity_Data,
}

entity_count :: proc(scene: Scene) -> int {
	count := 0
	for entity in scene.entities {
		count += count_entity_tree(entity)
	}
	return count
}

count_entity_tree :: proc(entity: Entity_Data) -> int {
	count := 1
	for child in entity.children {
		count += count_entity_tree(child)
	}
	return count
}

Scene :: struct {
	name:     string,
	entities: []Entity_Data,
}

// load reads a scene document and returns the fully instantiated runtime World.
// The caller supplies the engine's component registry so built-ins and any
// game-defined component registrations are shared with the loaded scene.
load :: proc(path: string, registry: ^ecs.Component_Registry) -> (ecs.World, bool) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		return {}, false
	}

	scene: Scene
	if json.unmarshal(data, &scene) != nil {
		return {}, false
	}

	world := ecs.init()
	if !instantiate(&world, registry, scene) {
		return {}, false
	}

	return world, true
}

// register_components discovers all component names used by a scene and makes
// missing names available as JSON-backed components. Built-in component names
// still receive their typed storage when they are attached to a World; custom
// components remain data until game code gives them behaviour.
register_components :: proc(registry: ^ecs.Component_Registry, scene: Scene) {
	for entity in scene.entities {
		register_entity_components(registry, entity)
	}
}

register_entity_components :: proc(registry: ^ecs.Component_Registry, entity: Entity_Data) {
	for name in entity.components {
		if !ecs.has_component(registry, name) {
			ecs.register_component(registry, ecs.Component_Descriptor{
				name = name,
				description = "Auto-registered from scene JSON",
			})
		}
	}

	for child in entity.children {
		register_entity_components(registry, child)
	}
}

// instantiate creates scene entities and attaches their component data. It
// automatically registers any component names declared by the scene first.
instantiate :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, scene: Scene) -> bool {
	register_components(registry, scene)
	for entity in scene.entities {
		if !instantiate_entity(world, registry, entity, ecs.Entity(0)) {
			return false
		}
	}
	return true
}

instantiate_entity :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, entity_data: Entity_Data, parent: ecs.Entity) -> bool {
	entity := ecs.create_entity(world)
	if parent != ecs.Entity(0) && !ecs.set_parent(world, entity, parent) {
		return false
	}
	for name, data in entity_data.components {
		if !ecs.add_component(world, registry, entity, name, data) {
			return false
		}
	}

	for child in entity_data.children {
		if !instantiate_entity(world, registry, child, entity) {
			return false
		}
	}
	return true
}
