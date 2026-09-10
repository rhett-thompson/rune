package save

import "core:encoding/json"
import "core:strings"
import "core:path/filepath"
import "rune:ecs"
import "rune:scene"

capture :: proc(manager: ^Manager, world: ^ecs.World) -> bool {
	clear_error(manager)
	if !manager.initialized || manager.checkpoint.document.active_scene == "" {return fail(manager, "No save scene baseline; call begin_scene before gameplay")}
	next, ok := clone_checkpoint(&manager.checkpoint)
	if !ok {return fail(manager, "Could not allocate checkpoint")}
	defer destroy_checkpoint(&next)
	a := allocator(&next)
	key := next.document.active_scene
	previous := next.document.scenes[key]
	state := Scene_State{baseline = previous.baseline, entities = make(map[string]Entity_State, a)}
	policies := make([dynamic]string, a)
	for name in manager.policies {append(&policies, strings.clone(name, a) or_else "")}
	state.policies = policies[:]
	removed := make([dynamic]string, a)
	for id in state.baseline {
		if _, found := ecs.find_entity_by_id(world, id); !found {append(&removed, id)}
	}
	state.removed = removed[:]
	baseline := make(map[string]bool, context.temp_allocator)
	for id in state.baseline {baseline[id] = true}
	for entity, id in world.entity_ids {
		if id == "" || (!baseline[id] && !manager.spawned[id]) {continue}
		record := Entity_State{spawned = manager.spawned[id], enabled = ecs.is_locally_enabled(world, entity),
			layers = world.layer_masks[entity], name = strings.clone(world.entity_names[entity], a) or_else "",
			tag = strings.clone(world.entity_tags[entity], a) or_else "",
			components = make(map[string]json.Value, a), state = make(map[string]json.Value, a)}
		if parent, has_parent := ecs.get_parent(world, entity); has_parent {
			parent_id := world.entity_ids[parent]
			if parent_id == "" || (!baseline[parent_id] && !manager.spawned[parent_id]) {return fail(manager, "Saved entity '%s' has an unsaved parent", id)}
			record.parent = strings.clone(parent_id, a) or_else ""
		}
		for name in world.component_data {
			if !ecs.has_component_data(world, entity, name) {continue}
			adapter, selected := manager.policies[name]
			if !selected && !record.spawned {continue}
			owned_name := strings.clone(name, a) or_else ""
			// Adapters own the complete saved representation and must create the
			// component themselves when restoring a runtime-spawned entity.
			if adapter.capture == nil {
				descriptor := world.component_descriptors[name]
				if descriptor.type_id != nil && !automatic_type_safe(type_info_of(descriptor.type_id)) {return fail(manager, "Saved spawn '%s.%s' requires a custom adapter", id, name)}
				value, captured := ecs.runtime_component_json(world, entity, name, a)
				if !captured {return fail(manager, "Could not save '%s.%s'", id, name)}
				record.components[owned_name] = value
			}
			if selected && adapter.capture != nil {
				value, captured := adapter.capture(world, entity, a)
				if !captured {return fail(manager, "Save adapter failed for '%s.%s'", id, name)}
				record.state[owned_name] = json.clone_value(value, a)
			}
		}
		state.entities[strings.clone(id, a) or_else ""] = record
	}
	next.document.scenes[key] = state
	commit(manager, &next)
	return true
}

// Prepare a fresh scene, apply its checkpoint, and validate before publishing.
// The caller owns both the returned World and candidate checkpoint on success.
prepare_scene :: proc(manager: ^Manager, checkpoint: ^Checkpoint, path: string,
	registry: ^ecs.Component_Registry, layers: map[string]u8) -> (ecs.World, bool) {
	a := allocator(checkpoint)
	key, valid := scene_key(manager, path, a)
	if !valid {return {}, false}
	full_path, _ := filepath.join({manager.project_directory, key}, context.temp_allocator)
	world, loaded := scene.load_with_layers(full_path, registry, layers)
	if !loaded {return {}, fail(manager, "Could not load save scene '%s': %s", key, scene.last_load_error())}
	success := false
	defer if !success {ecs.destroy(&world)}
	state, visited := checkpoint.document.scenes[key]
	// Baseline comes from the current authored scene, before saved removals.
	baseline := make([dynamic]string, a)
	for _, id in world.entity_ids {if id != "" {append(&baseline, strings.clone(id, a) or_else "")}}
	if visited && !apply_state(manager, &world, registry, state) {return {}, false}
	state.baseline = baseline[:]
	if !visited {state.entities = make(map[string]Entity_State, a)}
	checkpoint.document.scenes[key] = state
	checkpoint.document.active_scene = key
	if manager.options.prepare != nil && !manager.options.prepare(&world, &checkpoint.document) {return {}, fail(manager, "Game rejected restored scene '%s'", key)}
	success = true
	return world, true
}

apply_state :: proc(manager: ^Manager, world: ^ecs.World, registry: ^ecs.Component_Registry, state: Scene_State) -> bool {
	selected := make(map[string]bool, context.temp_allocator)
	for name in state.policies {
		if _, known := manager.policies[name]; !known || selected[name] {return fail(manager, "Unknown or duplicate saved policy '%s'; migrate the save", name)}
		selected[name] = true
	}
	removed := make(map[string]bool, context.temp_allocator)
	for id in state.removed {
		if id == "" || removed[id] {return fail(manager, "Invalid removed entity '%s'", id)}
		if _, exists := state.entities[id]; exists {return fail(manager, "Entity '%s' is both present and removed", id)}
		removed[id] = true
	}
	// Detach surviving entities first: a saved reparenting can rescue a child
	// whose original scene parent was deleted during play.
	for id, record in state.entities {
		if id == "" || record.layers == 0 {return fail(manager, "Invalid saved entity '%s'", id)}
		entity, exists := ecs.find_entity_by_id(world, id)
		if record.spawned {
			if exists {return fail(manager, "Saved spawn ID '%s' collides with the scene", id)}
			entity = ecs.create_entity(world)
			if !ecs.set_entity_metadata(world, entity, id, record.name, record.tag, record.layers) {return fail(manager, "Could not create saved entity '%s'", id)}
		} else if !exists {return fail(manager, "Saved entity '%s' no longer exists; migrate the save", id)}
		if !ecs.set_parent(world, entity, ecs.Entity(0)) {return fail(manager, "Could not detach '%s'", id)}
	}
	for id in removed {
		if entity, exists := ecs.find_entity_by_id(world, id); exists {ecs.destroy_entity(world, entity)}
	}
	for id, record in state.entities {
		entity, exists := ecs.find_entity_by_id(world, id)
		if !exists {return fail(manager, "Saved hierarchy removed '%s'", id)}
		if !ecs.set_entity_metadata(world, entity, id, record.name, record.tag, record.layers) {return fail(manager, "Invalid metadata for '%s'", id)}
		ecs.set_enabled(world, entity, record.enabled)
		// Removing selected components before adding replacements also permits
		// changing mutually exclusive component configurations without ordering.
		for name in selected {
			adapter := manager.policies[name]
			_, has_state := record.state[name]
			if adapter.restore == nil || !has_state {
				if ecs.has_component_data(world, entity, name) {ecs.remove_component(world, entity, name)}
			}
		}
		for name, value in record.components {
			if !record.spawned && !selected[name] {return fail(manager, "Unregistered saved field '%s.%s'", id, name)}
			if !ecs.add_component(world, registry, entity, name, value) {return fail(manager, "Invalid saved component '%s.%s'", id, name)}
		}
		if record.parent != "" {
			parent, found := ecs.find_entity_by_id(world, record.parent)
			if !found || !ecs.set_parent(world, entity, parent) {return fail(manager, "Invalid saved parent for '%s'", id)}
		}
	}
	// Second pass: all component data and stable IDs now exist.
	for id, record in state.entities {
		entity, _ := ecs.find_entity_by_id(world, id)
		for name, value in record.state {
			adapter, exists := manager.policies[name]
			if !exists || !selected[name] || adapter.restore == nil {return fail(manager, "Missing restore adapter '%s'", name)}
			if !adapter.restore(world, entity, value) {return fail(manager, "Restore adapter failed for '%s.%s'", id, name)}
		}
	}
	return true
}
