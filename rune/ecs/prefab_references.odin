package ecs

import "core:strings"

// find_prefab_child resolves a local child ID path under one particular instance.
// Names are display-only. IDs and Entity_Ref survive reload; Entity handles may not.
find_prefab_child :: proc(world: ^World, instance: Entity, path: string) -> (Entity, bool) {
	id, found := entity_id(world, instance)
	if !found || id == "" || path == "" {return 0, false}
	full_id := strings.concatenate({id, "/", path}, context.temp_allocator)
	entity, exists := find_entity_by_id(world, full_id)
	if !exists {return 0, false}
	// A scene-authored ID containing slashes must not impersonate a descendant.
	for parent := world.parents[entity]; parent != 0; parent = world.parents[parent] {
		if parent == instance {return entity, true}
	}
	return 0, false
}
