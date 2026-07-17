package scene

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "rune:ecs"
import "rune:prefab"
import "rune:validation"

Entity_Data :: struct {
	id:         string,
	name:       string,
	tag:        string,
	layers:     []string,
	prefab:     string,
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

last_load_error_message: string

clear_load_error :: proc() {
	if len(last_load_error_message) > 0 { delete(last_load_error_message) }
	last_load_error_message = ""
}

set_load_error :: proc(format: string, args: ..any) {
	clear_load_error()
	last_load_error_message = fmt.aprintf(format, ..args)
}

last_load_error :: proc() -> string { return last_load_error_message }

// dependency_paths returns a scene file and all directly referenced prefab
// files. Prefab references are relative to the owning scene file.
dependency_paths :: proc(path: string) -> ([]string, bool) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil { return nil, false }
	scene: Scene
	if json.unmarshal(data, &scene) != nil { return nil, false }

	result := make([dynamic]string, context.allocator)
	append(&result, path)
	scene_directory, _ := filepath.split(path)
	for entity in scene.entities {
		if !collect_entity_dependencies(&result, entity, scene_directory) { return nil, false }
	}
	return result[:], true
}

collect_entity_dependencies :: proc(paths: ^[dynamic]string, entity: Entity_Data, scene_directory: string) -> bool {
	if len(entity.prefab) > 0 {
		prefab_path := entity.prefab
		if !filepath.is_abs(prefab_path) {
			prefab_path, _ = filepath.join({scene_directory, prefab_path})
		}
		if _, loaded := prefab.load(prefab_path); !loaded { return false }
		append(paths, prefab_path)
	}
	for child in entity.children {
		if !collect_entity_dependencies(paths, child, scene_directory) { return false }
	}
	return true
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
load_with_layers :: proc(path: string, registry: ^ecs.Component_Registry, layer_names: map[string]u8) -> (ecs.World, bool) {
	clear_load_error()
	validation_report := validation.validate_scene_with_layers(path, layer_names)
	if !validation.is_valid(&validation_report) {
		if len(validation_report.diagnostics) > 0 {
			diagnostic := validation_report.diagnostics[0]
			set_load_error("%s: %s: %s", diagnostic.file, diagnostic.path, diagnostic.message)
		}
		return {}, false
	}
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		set_load_error("%s: could not read scene", path)
		return {}, false
	}

	scene: Scene
	if json.unmarshal(data, &scene) != nil {
		set_load_error("%s: could not deserialize scene", path)
		return {}, false
	}
	root_json: json.Value
	if json.unmarshal(data, &root_json) != nil {
		set_load_error("%s: could not preserve scene JSON", path)
		return {}, false
	}

	scene_directory, _ := filepath.split(path)
	world := ecs.init()
	ecs.set_scene_json(&world, root_json)
	if !instantiate_with_layers_at(&world, registry, scene, layer_names, scene_directory) {
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

instantiate_with_layers :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, scene: Scene, layer_names: map[string]u8) -> bool {
	return instantiate_with_layers_at(world, registry, scene, layer_names, "")
}

instantiate_with_layers_at :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, scene: Scene, layer_names: map[string]u8, scene_directory: string) -> bool {
	for entity in scene.entities {
		if !instantiate_entity(world, registry, entity, ecs.Entity(0), layer_names, scene_directory) {
			return false
		}
	}
	return true
}

instantiate_entity :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, entity_data: Entity_Data, parent: ecs.Entity, layer_names: map[string]u8, scene_directory: string) -> bool {
	components := entity_data.components
	prefab_children: []prefab.Entity_Data
	if len(entity_data.prefab) > 0 {
		prefab_path := entity_data.prefab
		if !filepath.is_abs(prefab_path) {
			prefab_path, _ = filepath.join({scene_directory, prefab_path})
		}
		prefab_data, prefab_ok := prefab.load(prefab_path)
		if !prefab_ok {
			set_load_error("Could not load prefab '%s' for entity '%s'", prefab_path, entity_data.id)
			return false
		}
		components = prefab.merge_components(prefab_data.components, entity_data.components)
		prefab_children = prefab_data.children
	}

	entity := ecs.create_entity(world)
	layer_mask, layers_ok := layer_mask_from_names(entity_data.layers, layer_names)
	if !layers_ok || !ecs.set_entity_metadata(world, entity, entity_data.id, entity_data.name, entity_data.tag, layer_mask) {
		set_load_error("Could not create scene entity '%s'", entity_data.id)
		return false
	}
	if parent != ecs.Entity(0) && !ecs.set_parent(world, entity, parent) {
		return false
	}
	for name, data in components {
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
		if !instantiate_entity(world, registry, child, entity, layer_names, scene_directory) {
			return false
		}
	}
	for child in prefab_children {
		if !instantiate_prefab_child(world, registry, child, entity, layer_mask) { return false }
	}
	return true
}

instantiate_prefab_child :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, child_data: prefab.Entity_Data, parent: ecs.Entity, layer_mask: u64) -> bool {
	child := ecs.create_entity(world)
	if !ecs.set_entity_metadata(world, child, "", child_data.name, "", layer_mask) || !ecs.set_parent(world, child, parent) {
		return false
	}
	for name, data in child_data.components {
		if !ecs.has_component(registry, name) {
			set_load_error("Prefab child '%s' uses unregistered component '%s'", child_data.name, name)
			return false
		}
		if !ecs.add_component(world, registry, child, name, data) {
			set_load_error("Prefab child '%s' has invalid data for component '%s'", child_data.name, name)
			return false
		}
	}
	for grandchild in child_data.children {
		if !instantiate_prefab_child(world, registry, grandchild, child, layer_mask) { return false }
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
