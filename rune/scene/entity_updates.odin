package scene

import "core:encoding/json"
import "rune:ecs"

// A pair of resolved source trees for an entity already in the World. Both
// roots must have the live entity's ID. Every child needs a unique, qualified
// ID, and layers must already include any inheritance the caller requires.
Entity_Update :: struct {
	entity: ecs.Entity,
	before, after: Entity_Data,
	preserve_root_metadata: bool,
}

// Instantiate a resolved tree and return its root. If a child or component
// fails to load, remove all entities allocated by this call.
instantiate_entity_tree :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, data: Entity_Data,
	parent: ecs.Entity, layer_names: map[string]u8) -> (ecs.Entity, bool) {
	if world == nil || registry == nil || world.next_entity == 0 {return 0, false}
	if parent != 0 && !ecs.is_alive(world, parent) {return 0, false}
	first := world.next_entity
	if instantiate_entity(world, registry, data, parent, layer_names) {
		return ecs.make_entity(world.generation, first), true
	}
	allocated := make([]ecs.Entity, int(world.next_entity - first), context.temp_allocator)
	for &entity, index in allocated {entity = ecs.make_entity(world.generation, first + u32(index))}
	ecs.destroy_entities(world, allocated)
	return 0, false
}

@(private="file")
Component_Edit :: struct {
	entity: ecs.Entity,
	name: string,
	value, previous: json.Value,
	remove, had_previous: bool,
}

@(private="file")
Metadata_Edit :: struct {
	entity: ecs.Entity,
	id, name, tag: string,
	layers: u64,
	enabled, set_enabled: bool,
}

@(private="file")
Child_Addition :: struct {parent: ecs.Entity, data: Entity_Data}

@(private="file")
Entity_Edit_Plan :: struct {
	components: [dynamic]Component_Edit,
	metadata: [dynamic]Metadata_Edit,
	additions: [dynamic]Child_Addition,
	removals: [dynamic]ecs.Entity,
}

// Apply source changes to disjoint subtrees without replacing retained
// entities. Source object fields that did not change keep their live values.
// Retained entities also keep their runtime-only components and children.
// The caller owns the source trees and calls this on the World owner thread.
apply_entity_updates :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, updates: []Entity_Update,
	layer_names: map[string]u8) -> bool {
	if world == nil || registry == nil {return false}
	if len(updates) == 0 {return true}
	roots := make(map[ecs.Entity]bool, context.temp_allocator)
	for update in updates {
		if roots[update.entity] || !ecs.is_alive(world, update.entity) {return false}
		roots[update.entity] = true
	}
	plan := Entity_Edit_Plan{
		components = make([dynamic]Component_Edit, context.temp_allocator),
		metadata = make([dynamic]Metadata_Edit, context.temp_allocator),
		additions = make([dynamic]Child_Addition, context.temp_allocator),
		removals = make([dynamic]ecs.Entity, context.temp_allocator),
	}
	for update in updates {
		parent := ecs.get_parent(world, update.entity) or_else 0
		for parent != 0 {
			if roots[parent] {return false}
			parent = ecs.get_parent(world, parent) or_else 0
		}
		if !plan_entity_update(world, update.entity, update.before, update.after, layer_names, &plan, update.preserve_root_metadata) {
			set_load_error("Could not update entity tree '%s' (invalid ID, hierarchy, or layers)", update.after.id)
			return false
		}
	}
	if !validate_component_edits(world, registry, plan.components[:]) {return false}

	added := make([dynamic]ecs.Entity, 0, len(plan.additions), context.temp_allocator)
	committed := false
	defer if !committed {ecs.destroy_entities(world, added[:])}
	for entry in plan.additions {
		child, created := instantiate_entity_tree(world, registry, entry.data, entry.parent, layer_names)
		if !created {return false}
		append(&added, child)
	}
	if !apply_component_edits(world, registry, plan.components[:]) {return false}
	for entry in plan.metadata {
		ecs.set_entity_metadata(world, entry.entity, entry.id, entry.name, entry.tag, entry.layers)
		if entry.set_enabled {ecs.set_enabled(world, entry.entity, entry.enabled)}
	}
	ecs.destroy_entities(world, plan.removals[:])
	committed = true
	return true
}

@(private="file")
plan_entity_update :: proc(world: ^ecs.World, entity: ecs.Entity, before, after: Entity_Data, layer_names: map[string]u8,
	plan: ^Entity_Edit_Plan, preserve_metadata := false) -> bool {
	id, identified := ecs.entity_id(world, entity)
	if !identified || id == "" || id != before.id || id != after.id {return false}
	if !preserve_metadata {
		layers, valid := layer_mask_from_names(after.layers, layer_names)
		if !valid {return false}
		name := ecs.entity_name(world, entity) or_else ""
		tag := ecs.entity_tag(world, entity) or_else ""
		if before.name != after.name {name = after.name}
		if before.tag != after.tag {tag = after.tag}
		was_enabled := before.enabled.(bool) or_else true
		enabled := after.enabled.(bool) or_else true
		change_enabled := was_enabled != enabled && ecs.is_locally_enabled(world, entity) == was_enabled
		append(&plan.metadata, Metadata_Edit{entity, id, name, tag, layers, enabled, change_enabled})
	}
	for name, previous_source in before.components {
		next, retained := after.components[name]
		if retained && ecs.json_values_equal(previous_source, next) {continue}
		current, present := ecs.runtime_component_json(world, entity, name)
		if !present {continue}
		value: json.Value
		if retained {value = merge_source_fields(previous_source, next, current)}
		append(&plan.components, Component_Edit{entity, name, value, current, !retained, true})
	}
	for name, next in after.components {
		if _, present := before.components[name]; present {continue}
		current, present := ecs.runtime_component_json(world, entity, name)
		append(&plan.components, Component_Edit{entity, name, next, current, false, present})
	}
	old_children, old_valid := index_update_children(before.children)
	new_children, new_valid := index_update_children(after.children)
	if !old_valid || !new_valid {return false}
	for previous in before.children {
		child, found := ecs.find_entity_by_id(world, previous.id)
		if !found {continue}
		if (ecs.get_parent(world, child) or_else 0) != entity {return false}
		if next, retained := new_children[previous.id]; retained {
			if !plan_entity_update(world, child, previous, next, layer_names, plan) {return false}
		} else {
			append(&plan.removals, child)
		}
	}
	for next in after.children {
		if _, retained := old_children[next.id]; retained {continue}
		if _, found := ecs.find_entity_by_id(world, next.id); found {return false}
		append(&plan.additions, Child_Addition{entity, next})
	}
	return true
}

@(private="file")
index_update_children :: proc(children: []Entity_Data) -> (map[string]Entity_Data, bool) {
	result := make(map[string]Entity_Data, context.temp_allocator)
	for child in children {
		if _, duplicate := result[child.id]; child.id == "" || duplicate {return nil, false}
		result[child.id] = child
	}
	return result, true
}

@(private="file")
merge_source_fields :: proc(before, after, current: json.Value) -> json.Value {
	if ecs.json_values_equal(before, after) {return current}
	old, old_object := before.(json.Object)
	next, new_object := after.(json.Object)
	live, live_object := current.(json.Object)
	if !old_object || !new_object || !live_object {return after}
	merged := make(json.Object, context.temp_allocator)
	for name, value in live {merged[name] = value}
	for name in old {
		if _, retained := next[name]; !retained {delete_key(&merged, name)}
	}
	for name, value in next {
		if previous, found := old[name]; found && ecs.json_values_equal(previous, value) {continue}
		merged[name] = merge_source_fields(old[name], value, live[name])
	}
	return merged
}

@(private="file")
validate_component_edits :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, edits: []Component_Edit) -> bool {
	if len(edits) == 0 {return true}
	pending := make(map[ecs.Entity]map[string]bool, context.temp_allocator)
	for entry in edits {
		membership := pending[entry.entity]
		if membership == nil {
			membership = make(map[string]bool, context.temp_allocator)
			pending[entry.entity] = membership
		}
		membership[entry.name] = !entry.remove
	}
	scratch := ecs.init()
	defer ecs.destroy(&scratch)
	probes := make(map[ecs.Entity]ecs.Entity, context.temp_allocator)
	for entry in edits {
		if entry.remove {continue}
		if !ecs.component_attachment_allowed(world, entry.entity, entry.name, pending[entry.entity]) {
			set_load_error("Edited component '%s' conflicts with a component on its live entity", entry.name)
			return false
		}
		probe := probes[entry.entity]
		if probe == 0 {
			probe = ecs.create_entity(&scratch)
			probes[entry.entity] = probe
		}
		if !ecs.add_component(&scratch, registry, probe, entry.name, entry.value) {
			set_load_error("Invalid edited data for component '%s'", entry.name)
			return false
		}
	}
	return true
}

@(private="file")
apply_component_edits :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, edits: []Component_Edit) -> bool {
	completed := make([dynamic]Component_Edit, 0, len(edits), context.temp_allocator)
	for entry in edits {
		if entry.remove && ecs.remove_component(world, entry.entity, entry.name) {append(&completed, entry)}
	}
	for entry in edits {
		if entry.remove {continue}
		if !ecs.add_component(world, registry, entry.entity, entry.name, entry.value) {
			// The live entity can have components outside the source tree. Restore
			// completed changes in reverse order if one conflicts with an edit.
			for i := len(completed) - 1; i >= 0; i -= 1 {
				edit := completed[i]
				if edit.had_previous {ecs.add_component(world, registry, edit.entity, edit.name, edit.previous)}
				else {ecs.remove_component(world, edit.entity, edit.name)}
			}
			set_load_error("Could not apply edited component '%s'", entry.name)
			return false
		}
		append(&completed, entry)
	}
	return true
}
