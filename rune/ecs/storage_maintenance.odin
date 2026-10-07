package ecs

import "core:encoding/json"
import "core:mem"

Owned_Component_JSON :: struct {value: json.Value, allocator: mem.Allocator}

@(private)
release_component_json :: proc(world: ^World, entity: Entity, name: string) {
	key := Component_Change_Key{entity = entity, name = name}
	if value, found := world.owned_component_json[key]; found {
		delete_key(&world.owned_component_json, key)
		json.destroy_value(value.value, value.allocator)
	}
}

@(private)
destroy_owned_component_json :: proc(world: ^World) {
	for _, value in world.owned_component_json {json.destroy_value(value.value, value.allocator)}
	delete(world.owned_component_json)
	world.owned_component_json = nil
}

// Reclaim unreachable scene JSON/strings at a caller-selected safe point.
// Invalidates borrowed scene JSON, strings, and metadata; Entity handles,
// resource pointers, custom typed values, physics, and mesh buffers stay valid.
// Copies live storage before freeing old storage, so peak memory rises briefly.
compact_scene_storage :: proc(world: ^World) -> bool {
	if world == nil || world.scene_data_arena == nil {return false}
	arena, err := mem.new(mem.Dynamic_Arena)
	if err != nil {return false}
	mem.dynamic_arena_init(arena)
	storage := World{scene_data_arena = arena, scene_strings = make(map[string]string)}
	world.scene_json = json.clone_value(world.scene_json, scene_data_allocator(&storage))
	// Preserve the authored baseline, including authored entities/components
	// removed at runtime. Capturing the current World would change reload rules.
	source := clone_scene_source(world.scene_source, &storage)
	destroy_scene_source(&world.scene_source)
	world.scene_source = source
	adopt_snapshot_storage(world, &storage)
	return true
}

@(private)
clone_scene_source :: proc(source: Scene_Source, storage: ^World) -> Scene_Source {
	if !source.captured {return {}}
	result := Scene_Source{
		captured = true, entity_ids = make(map[Entity]string),
		metadata = make(map[Entity]Scene_Entity_Metadata), parents = make(map[Entity]Entity),
		components = make(map[string]map[Entity]json.Value),
		instances = make(map[string]map[Component_Instance]json.Value),
	}
	for entity, id in source.entity_ids {result.entity_ids[entity] = retain_scene_string(storage, id)}
	for entity, metadata in source.metadata {
		owned := metadata
		owned.name = retain_scene_string(storage, metadata.name)
		owned.tag = retain_scene_string(storage, metadata.tag)
		result.metadata[entity] = owned
	}
	for entity, parent in source.parents {result.parents[entity] = parent}
	for name, values in source.components {
		components := make(map[Entity]json.Value)
		for entity, value in values {components[entity] = json.clone_value(value, scene_data_allocator(storage))}
		result.components[retain_scene_string(storage, name)] = components
	}
	for name, values in source.instances {
		instances := make(map[Component_Instance]json.Value)
		for key, value in values {
			owned_key := key
			owned_key.name = retain_scene_string(storage, key.name)
			instances[owned_key] = json.clone_value(value, scene_data_allocator(storage))
		}
		result.instances[retain_scene_string(storage, name)] = instances
	}
	return result
}

// Discard acknowledged records for components that no longer exist. Live
// component versions remain available to navigation and interaction caches.
// Consumers must acknowledge only after all interested systems have read them.
prune_component_changes :: proc(world: ^World, through_version: u64) -> bool {
	if world == nil || through_version > world.component_change_version {return false}
	for key, change in world.component_changes {
		if change.version <= through_version && !has_component_data(world, key.entity, key.name) {
			delete_key(&world.component_changes, key)
		}
	}
	world.component_history_floor = max(world.component_history_floor, through_version)
	return true
}

// complete=false means the cursor predates acknowledged history. Rescan
// current membership before using change_version(world) as a fresh cursor.
changes_since_checked :: proc(world: ^World, $T: typeid, version: u64) -> (changes: []Component_Change, complete: bool) {
	if world == nil {return nil, false}
	return changes_since(world, T, version), version >= world.component_history_floor && version <= world.component_change_version
}
