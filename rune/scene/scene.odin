package scene

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "rune:ecs"
import "rune:prefab"
import "rune:validation"

Entity_Data :: struct {
	enabled: Maybe(bool) `json:"enabled,omitempty"`,
	id: string `json:"id,omitempty"`,
	name: string `json:"name,omitempty"`,
	tag: string `json:"tag,omitempty"`,
	layers: []string `json:"layers,omitempty"`,
	prefab: string `json:"prefab,omitempty"`,
	components: map[string]json.Value `json:"components,omitempty"`,
	component_overrides: map[string]json.Value `json:"component_overrides,omitempty"`,
	remove_components: []string `json:"remove_components,omitempty"`,
	child_overrides: map[string]json.Value `json:"child_overrides,omitempty"`,
	children: []Entity_Data `json:"children,omitempty"`,
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

last_load_error_message: string

clear_load_error :: proc() {
	if len(last_load_error_message) > 0 {delete(last_load_error_message)}
	last_load_error_message = ""
}

set_load_error :: proc(format: string, args: ..any) {
	clear_load_error()
	last_load_error_message = fmt.aprintf(format, ..args)
}

last_load_error :: proc() -> string {return last_load_error_message}

// dependency_paths includes transitive prefab references, relative to their owner.
dependency_paths :: proc(path: string) -> ([]string, bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {return nil, false}
	value: json.Value
	if json.unmarshal(data, &value, allocator = allocator) != nil {return nil, false}
	resolved := prefab.resolve_scene(value, path, allocator)
	if resolved.error != "" {return nil, false}
	result := make([]string, len(resolved.dependencies))
	for path, index in resolved.dependencies {result[index], _ = strings.clone(path)}
	return result, true
}

destroy_dependency_paths :: proc(paths: []string) {
	for path in paths {delete(path)}
	delete(paths)
}

// load reads a scene document and returns the fully instantiated runtime World.
// The caller supplies the engine's component registry so built-ins and any
// game-defined component registrations are shared with the loaded scene.
load :: proc(path: string, registry: ^ecs.Component_Registry) -> (ecs.World, bool) {
	return load_with_layers(path, registry, nil)
}

// load_with_layers resolves the readable layer names in a scene against the
// project's layer table. Passing nil supports standalone scenes that only use
// the implicit Default layer.
load_with_layers :: proc(
	path: string,
	registry: ^ecs.Component_Registry,
	layer_names: map[string]u8,
) -> (
	ecs.World,
	bool,
) {
	clear_load_error()
	validation_report := validation.validate_scene_with_layers(path, layer_names)
	defer validation.destroy_report(&validation_report)
	if !validation.is_valid(&validation_report) {
		if len(validation_report.diagnostics) > 0 {
			diagnostic := validation_report.diagnostics[0]
			set_load_error("%s: %s: %s", diagnostic.file, diagnostic.path, diagnostic.message)
		}
		return {}, false
	}
	parse_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&parse_arena)
	defer mem.dynamic_arena_destroy(&parse_arena)
	parse_allocator := mem.dynamic_arena_allocator(&parse_arena)
	data, read_error := os.read_entire_file(path, parse_allocator)
	if read_error != nil {
		set_load_error("%s: could not read scene", path)
		return {}, false
	}

	root_json: json.Value
	if json.unmarshal(data, &root_json, allocator = parse_allocator) != nil {
		set_load_error("%s: could not deserialize scene", path)
		return {}, false
	}
	resolved := prefab.resolve_scene(root_json, path, parse_allocator)
	if resolved.error != "" {set_load_error("%s", resolved.error); return {}, false}
	world := ecs.init()
	ecs.set_scene_json(&world, root_json)
	if !instantiate_resolved(&world, registry, resolved.value, layer_names, parse_allocator) {
		ecs.destroy(&world)
		return {}, false
	}
	return world, true
}

// instantiate creates scene entities and attaches their component data.
// Every component name must already be registered so authoring typos fail.
instantiate :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, scene: Scene) -> bool {
	return instantiate_with_layers(world, registry, scene, nil)
}

instantiate_with_layers :: proc(
	world: ^ecs.World,
	registry: ^ecs.Component_Registry,
	scene: Scene,
	layer_names: map[string]u8,
) -> bool {
	return instantiate_with_layers_at(world, registry, scene, layer_names, "")
}

instantiate_with_layers_at :: proc(
	world: ^ecs.World, registry: ^ecs.Component_Registry, scene: Scene,
	layer_names: map[string]u8, scene_directory: string, allocator := context.allocator,
) -> bool {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch := mem.dynamic_arena_allocator(&arena)
	data, error := json.marshal(scene, allocator = scratch)
	if error != nil {set_load_error("Could not serialize scene data"); return false}
	value: json.Value
	if json.unmarshal(data, &value, allocator = scratch) != nil {return false}
	file, _ := filepath.join({scene_directory, "__inline.scene.json"}, scratch)
	resolved := prefab.resolve_scene(value, file, scratch)
	if resolved.error != "" {set_load_error("%s", resolved.error); return false}
	return instantiate_resolved(world, registry, resolved.value, layer_names, scratch)
}

instantiate_resolved :: proc(
	world: ^ecs.World, registry: ^ecs.Component_Registry, value: json.Value,
	layer_names: map[string]u8, allocator: mem.Allocator,
) -> bool {
	data, error := json.marshal(value, allocator = allocator)
	if error != nil {set_load_error("Could not serialize resolved scene"); return false}
	scene: Scene
	if json.unmarshal(data, &scene, allocator = allocator) != nil {
		set_load_error("Could not deserialize resolved scene")
		return false
	}
	for entity in scene.entities {
		if !instantiate_entity(world, registry, entity, ecs.Entity(0), layer_names) {return false}
	}
	return true
}

instantiate_entity :: proc(
	world: ^ecs.World, registry: ^ecs.Component_Registry, entity_data: Entity_Data,
	parent: ecs.Entity, layer_names: map[string]u8,
) -> bool {
	entity := ecs.create_entity(world)
	enabled := true
	if value, specified := entity_data.enabled.(bool); specified {enabled = value}
	ecs.set_enabled(world, entity, enabled)
	layer_mask, layers_ok := layer_mask_from_names(entity_data.layers, layer_names)
	if !layers_ok || !ecs.set_entity_metadata(world, entity, entity_data.id, entity_data.name, entity_data.tag, layer_mask) {
		set_load_error("Could not create scene entity '%s' (duplicate ID or invalid layers)", entity_data.id)
		return false
	}
	if parent != ecs.Entity(0) && !ecs.set_parent(world, entity, parent) {return false}
	for name, data in entity_data.components {
		if !ecs.has_component(registry, name) {
			set_load_error("Entity '%s' uses unregistered component '%s'", entity_data.id, name)
			return false
		}
		if !ecs.add_component(world, registry, entity, name, data) {
			set_load_error("Entity '%s' has invalid data for component '%s'", entity_data.id, name)
			return false
		}
	}
	for child in entity_data.children {
		if !instantiate_entity(world, registry, child, entity, layer_names) {return false}
	}
	return true
}

layer_mask_from_names :: proc(layers: []string, layer_names: map[string]u8) -> (u64, bool) {
	if len(layers) == 0 {
		return ecs.Default_Layer_Mask, true
	}

	mask: u64
	for layer_name in layers {
		if layer_name == "Default" {
			mask |= ecs.Default_Layer_Mask
			continue
		}
		layer_index, found := layer_names[layer_name]
		if !found || layer_index >= 64 {
			return 0, false
		}
		mask |= u64(1) << layer_index
	}
	return mask, mask != 0
}
