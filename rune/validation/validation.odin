package validation

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "rune:jsonutil"

// Diagnostic describes one authoring problem. `path` is a JSON-style field
// path, so the same report can later be shown by command-line tools or an
// editor inspector.
Diagnostic :: struct {
	file:    string,
	path:    string,
	message: string,
}

Report :: struct {
	diagnostics: [dynamic]Diagnostic,
}

is_valid :: proc(report: ^Report) -> bool { return len(report.diagnostics) == 0 }

field_path :: proc(path, name: string) -> string { return fmt.tprint(path, ".", name) }
index_path :: proc(path: string, index: int) -> string { return fmt.tprint(path, "[", index, "]") }
layer_path :: proc(name: string) -> string { return fmt.tprint("$.layers.", name) }

add :: proc(report: ^Report, file, path, message: string) {
	append(&report.diagnostics, Diagnostic{file = file, path = path, message = message})
}

read_json_object :: proc(path: string, report: ^Report) -> (json.Object, bool) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		add(report, path, "$", "file could not be read")
		return nil, false
	}
	value: json.Value
	if json.unmarshal(data, &value) != nil {
		add(report, path, "$", "invalid JSON")
		return nil, false
	}
	object, ok := value.(json.Object)
	if !ok { add(report, path, "$", "expected an object") }
	return object, ok
}

string_field :: proc(report: ^Report, file, path: string, object: json.Object, name: string, required: bool) -> (string, bool) {
	value, found := object[name]
	if !found {
		if required { add(report, file, field_path(path, name), "is required") }
		return "", !required
	}
	result, ok := value.(json.String)
	if !ok || len(result) == 0 {
		add(report, file, field_path(path, name), "must be a non-empty string")
		return "", false
	}
	return result, true
}

object_field :: proc(report: ^Report, file, path: string, object: json.Object, name: string, required: bool) -> (json.Object, bool) {
	value, found := object[name]
	if !found {
		if required { add(report, file, field_path(path, name), "is required") }
		return nil, !required
	}
	result, ok := value.(json.Object)
	if !ok { add(report, file, field_path(path, name), "must be an object") }
	return result, ok
}

array_field :: proc(report: ^Report, file, path: string, object: json.Object, name: string, required: bool) -> (json.Array, bool) {
	value, found := object[name]
	if !found {
		if required { add(report, file, field_path(path, name), "is required") }
		return nil, !required
	}
	result, ok := value.(json.Array)
	if !ok { add(report, file, field_path(path, name), "must be an array") }
	return result, ok
}

path_from :: proc(directory, value: string) -> string {
	if filepath.is_abs(value) { return value }
	result, _ := filepath.join({directory, value})
	return result
}

file_exists :: proc(path: string) -> bool {
	_, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil
}

// validate_project validates the project document and follows its startup
// scene, input document, and directly referenced prefab files. Asset paths are
// resolved relative to the project file, matching the runtime asset manager.
validate_project :: proc(project_path: string) -> Report {
	report := Report{diagnostics = make([dynamic]Diagnostic)}
	project, ok := read_json_object(project_path, &report)
	if !ok { return report }
	project_directory, _ := filepath.split(project_path)
	startup_scene, scene_ok := string_field(&report, project_path, "$", project, "startup_scene", false)
	input_path, input_ok := string_field(&report, project_path, "$", project, "input", false)
	validate_window(&report, project_path, project)
	layers := validate_layers(&report, project_path, project)
	if input_ok && len(input_path) > 0 {
		resolved_input := path_from(project_directory, input_path)
		if !file_exists(resolved_input) { add(&report, project_path, "$.input", fmt.tprint("referenced input file does not exist: ", resolved_input)) }
	}
	if scene_ok && len(startup_scene) > 0 {
		validate_scene_at(&report, path_from(project_directory, startup_scene), layers, project_directory)
	}
	return report
}

validate_window :: proc(report: ^Report, file: string, project: json.Object) {
	window, found := project["window"]
	if !found { return }
	settings, ok := window.(json.Object)
	if !ok { add(report, file, "$.window", "must be an object"); return }
	dimension_fields := [2]string{"width", "height"}
	for field in dimension_fields {
		value, has_value := settings[field]
		if !has_value { continue }
		number, number_ok := jsonutil.number(value)
		if !number_ok || number != f32(i32(number)) || number <= 0 {
			add(report, file, field_path("$.window", field), "must be a positive integer")
		}
	}
	if value, has_title := settings["title"]; has_title {
		if _, title_ok := value.(json.String); !title_ok { add(report, file, "$.window.title", "must be a string") }
	}
}

validate_layers :: proc(report: ^Report, file: string, project: json.Object) -> map[string]u8 {
	result := make(map[string]u8)
	value, found := project["layers"]
	if !found { return result }
	layers, ok := value.(json.Object)
	if !ok { add(report, file, "$.layers", "must be an object"); return result }
	for name, index_value in layers {
		index, number_ok := jsonutil.number(index_value)
		if name == "Default" || !number_ok || index != f32(u8(index)) || index < 1 || index >= 64 {
			add(report, file, layer_path(name), "must be a unique integer from 1 through 63; Default is reserved")
			continue
		}
		for existing_name, existing_index in result {
			if existing_index == u8(index) { add(report, file, layer_path(name), fmt.tprint("reuses layer bit assigned to ", existing_name)) }
		}
		result[name] = u8(index)
	}
	return result
}

validate_scene :: proc(scene_path: string) -> Report {
	return validate_scene_with_layers(scene_path, nil)
}

// validate_scene_with_layers additionally checks scene layer names against the
// project's declared layer table. Standalone tools can pass nil when only the
// built-in Default layer is available.
validate_scene_with_layers :: proc(scene_path: string, layers: map[string]u8) -> Report {
	report := Report{diagnostics = make([dynamic]Diagnostic)}
	validate_scene_at(&report, scene_path, layers, "")
	return report
}

validate_scene_at :: proc(report: ^Report, scene_path: string, layers: map[string]u8, project_directory: string) {
	scene, ok := read_json_object(scene_path, report)
	if !ok { return }
	entities, entities_ok := array_field(report, scene_path, "$", scene, "entities", true)
	if !entities_ok { return }
	scene_directory, _ := filepath.split(scene_path)
	ids := make(map[string]bool)
	for entity, index in entities {
		validate_entity(report, scene_path, index_path("$.entities", index), entity, scene_directory, project_directory, layers, &ids)
	}
}

validate_entity :: proc(report: ^Report, file, path: string, value: json.Value, scene_directory, project_directory: string, layers: map[string]u8, ids: ^map[string]bool) {
	entity, ok := value.(json.Object)
	if !ok { add(report, file, path, "must be an object"); return }
	if id, id_ok := string_field(report, file, path, entity, "id", false); id_ok && len(id) > 0 {
		if ids^[id] { add(report, file, field_path(path, "id"), "duplicates another entity ID") }
		ids^[id] = true
	}
	validate_entity_layers(report, file, path, entity, layers)
	components, components_ok := object_field(report, file, path, entity, "components", false)
	if components_ok { validate_components(report, file, field_path(path, "components"), components, project_directory) }
	if prefab_path, prefab_ok := string_field(report, file, path, entity, "prefab", false); prefab_ok && len(prefab_path) > 0 {
		resolved_prefab := path_from(scene_directory, prefab_path)
		validate_prefab(report, resolved_prefab, project_directory)
	}
	children, children_ok := array_field(report, file, path, entity, "children", false)
	if children_ok {
		for child, child_index in children {
			validate_entity(report, file, index_path(field_path(path, "children"), child_index), child, scene_directory, project_directory, layers, ids)
		}
	}
}

validate_entity_layers :: proc(report: ^Report, file, path: string, entity: json.Object, layers: map[string]u8) {
	value, found := entity["layers"]
	if !found { return }
	values, ok := value.(json.Array)
	if !ok { add(report, file, field_path(path, "layers"), "must be an array of layer names"); return }
	for value, index in values {
		name, name_ok := value.(json.String)
		if !name_ok || len(name) == 0 { add(report, file, index_path(field_path(path, "layers"), index), "must be a non-empty string"); continue }
		if name != "Default" && layers != nil {
			if _, found := layers[name]; !found { add(report, file, index_path(field_path(path, "layers"), index), "is not declared by project.json") }
		}
	}
}

validate_prefab :: proc(report: ^Report, prefab_path, project_directory: string) {
	prefab, ok := read_json_object(prefab_path, report)
	if !ok { return }
	components, components_ok := object_field(report, prefab_path, "$", prefab, "components", false)
	if components_ok { validate_components(report, prefab_path, "$.components", components, project_directory) }
	children, children_ok := array_field(report, prefab_path, "$", prefab, "children", false)
	if children_ok {
		for child, index in children {
			validate_prefab_entity(report, prefab_path, index_path("$.children", index), child, project_directory)
		}
	}
}

validate_prefab_entity :: proc(report: ^Report, file, path: string, value: json.Value, project_directory: string) {
	entity, ok := value.(json.Object)
	if !ok { add(report, file, path, "must be an object"); return }
	components, components_ok := object_field(report, file, path, entity, "components", false)
	if components_ok { validate_components(report, file, field_path(path, "components"), components, project_directory) }
	children, children_ok := array_field(report, file, path, entity, "children", false)
	if children_ok {
		for child, index in children { validate_prefab_entity(report, file, index_path(field_path(path, "children"), index), child, project_directory) }
	}
}

validate_components :: proc(report: ^Report, file, path: string, components: json.Object, project_directory: string) {
	for name, value in components {
		component, ok := value.(json.Object)
		if !ok { add(report, file, field_path(path, name), "component data must be an object"); continue }
		if name == "AudioPlayer" {
			if len(component) == 0 { add(report, file, field_path(path, name), "must define at least one named instance"); continue }
			for instance_name, instance_value in component {
				instance, instance_ok := instance_value.(json.Object)
				instance_path := field_path(field_path(path, name), instance_name)
				if len(instance_name) == 0 || !instance_ok {
					add(report, file, instance_path, "named component instance must be an object")
					continue
				}
				validate_component_assets(report, file, instance_path, instance, project_directory)
			}
			continue
		}
		validate_component_assets(report, file, field_path(path, name), component, project_directory)
	}
}

validate_component_assets :: proc(report: ^Report, file, path: string, component: json.Object, project_directory: string) {
	asset_fields := [4]string{"texture", "model", "font", "sound"}
	for field in asset_fields {
		asset_path, found := component[field]
		if !found { continue }
		asset, ok := asset_path.(json.String)
		if !ok || len(asset) == 0 { add(report, file, field_path(path, field), "must be a non-empty asset path"); continue }
		if len(project_directory) > 0 && !file_exists(path_from(project_directory, asset)) {
			add(report, file, field_path(path, field), fmt.tprint("referenced asset does not exist: ", asset))
		}
	}
}
