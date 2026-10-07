package ecs

import "core:encoding/json"

// Borrowed read-only until instance/component removal or replacement,
// scene compaction, reload, or World destruction.
get_component_instance :: proc(
	world: ^World,
	entity: Entity,
	component_name, instance_name: string,
) -> (
	json.Value,
	bool,
) {
	instances, found := world.component_instance_data[component_name]
	if !found {return {}, false}
	value, instance_found := instances[Component_Instance{entity = entity, name = instance_name}]
	return value, instance_found
}

component_instance_names :: proc(
	world: ^World,
	entity: Entity,
	component_name: string,
) -> []string {
	instances, found := world.component_instance_data[component_name]
	if !found {return nil}
	result := make([dynamic]string, context.temp_allocator)
	for key in instances {
		if key.entity == entity {append(&result, key.name)}
	}
	return result[:]
}

remove_component_instance :: proc(
	world: ^World,
	entity: Entity,
	component_name, instance_name: string,
) -> bool {
	instances, found := world.component_instance_data[component_name]
	if !found {return false}
	// The caller may borrow the component name from the JSON being removed.
	component_name := retain_scene_string(world, component_name)
	key := Component_Instance {
		entity = entity,
		name   = instance_name,
	}
	if _, instance_found := instances[key]; !instance_found {return false}
	delete_key(&instances, key)
	world.component_instance_data[component_name] = instances
	if component_name == "AudioPlayer" {delete_key(&world.audio_players, key)}
	has_remaining := false
	for candidate in instances {
		if candidate.entity == entity {has_remaining = true; break}
	}
	if !has_remaining {
		if components, components_found := world.component_data[component_name]; components_found {
			delete_key(&components, entity)
			world.component_data[component_name] = components
		}
		release_component_json(world, entity, component_name)
	} else {
		components := world.component_data[component_name]
		if object, ok := components[entity].(json.Object); ok {
			// Owned roots reclaim the removed member too. Arena-backed roots
			// remain borrowed and are reclaimed by scene compaction.
			owner, owned := world.owned_component_json[{entity = entity, name = component_name}]
			removed := object[instance_name]
			stored_name := ""
			if owned {for name in object {if name == instance_name {stored_name = name; break}}}
			delete_key(&object, instance_name)
			components[entity] = object
			if owned {json.destroy_value(removed, owner.allocator); delete(stored_name, owner.allocator)}
		}
	}
	record_component_change(world, entity, component_name, .Changed if has_remaining else .Removed)
	return true
}
