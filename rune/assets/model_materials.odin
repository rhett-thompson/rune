package assets

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"

Model_Materials_Asset :: struct {
	sidecar_path: string,
	materials: map[i32]string,
	modified_time: i64,
}

// Borrow model-level material defaults from <model path>.materials.json. Keys
// are imported zero-based slots and values are project-relative material paths.
// Missing files are watched quietly so editors may create them during play.
// Borrowed maps and strings may be replaced by refresh_materials or shutdown.
model_material_paths :: proc(manager: ^Asset_Manager, model: string) -> map[i32]string {
	if manager == nil || model == "" {return nil}
	if cached, found := manager.model_materials[model]; found {return cached.materials}
	sidecar := fmt.aprintf("%s.materials.json", model)
	defer delete(sidecar)
	path := retain_path(manager, sidecar)
	full_path := resolve_path(manager, path)
	modified := modified_time(full_path)
	materials: map[i32]string
	if modified >= 0 {
		loaded, ok := load_model_material_paths(full_path)
		if ok {
			materials = loaded
		} else {
			report_failure(manager, {kind = .Material, operation = .Load, source_path = path,
				field = "$.materials", asset_path = path, detail = "invalid model material defaults"})
		}
	}
	if manager.model_materials == nil {manager.model_materials = make(map[string]Model_Materials_Asset)}
	manager.model_materials[retain_path(manager, model)] = {path, materials, modified}
	return materials
}

model_material_path :: proc(manager: ^Asset_Manager, model: string, slot: i32) -> string {
	return model_material_paths(manager, model)[slot]
}

// Return true only when a watched model's effective material defaults changed.
@(private)
refresh_model_materials :: proc(manager: ^Asset_Manager) -> bool {
	changed := false
	for _, &cached in manager.model_materials {
		full_path := resolve_path(manager, cached.sidecar_path)
		modified := modified_time(full_path)
		if modified == cached.modified_time {continue}
		cached.modified_time = modified
		if modified < 0 {
			changed = changed || len(cached.materials) > 0
			destroy_model_material_paths(cached.materials)
			cached.materials = nil
			resolve_asset_failure(manager, cached.sidecar_path, "$.materials", cached.sidecar_path)
			continue
		}
		materials, ok := load_model_material_paths(full_path)
		if !ok {
			report_failure(manager, {kind = .Material, operation = .Reload, source_path = cached.sidecar_path,
				field = "$.materials", asset_path = cached.sidecar_path,
				detail = "invalid model material defaults; keeping previous defaults"})
			continue
		}
		destroy_model_material_paths(cached.materials)
		cached.materials = materials
		resolve_asset_failure(manager, cached.sidecar_path, "$.materials", cached.sidecar_path)
		changed = true
	}
	return changed
}

// Successful data is owned by the caller, including every material path.
load_model_material_paths :: proc(path: string) -> (map[i32]string, bool) {
	bytes, error := os.read_entire_file(path, context.allocator)
	if error != nil {return nil, false}
	defer delete(bytes)
	value: json.Value
	if json.unmarshal(bytes, &value) != nil {return nil, false}
	defer json.destroy_value(value)
	return model_material_paths_from_json(value)
}

@(private)
model_material_paths_from_json :: proc(value: json.Value) -> (map[i32]string, bool) {
	object, ok := value.(json.Object)
	if !ok {return nil, false}
	materials, materials_ok := object["materials"].(json.Object)
	if !materials_ok {return nil, false}
	result := make(map[i32]string)
	valid := false
	defer if !valid {destroy_model_material_paths(result)}
	for key, value in materials {
		slot, slot_ok := strconv.parse_int(key, 10)
		path, path_ok := value.(json.String)
		if !slot_ok || slot < 0 || slot > 2147483647 || !path_ok || path == "" || filepath.is_abs(path) {return nil, false}
		if _, duplicate := result[i32(slot)]; duplicate {return nil, false}
		result[i32(slot)] = clone_asset_string(path)
	}
	valid = true
	return result, true
}

@(private)
destroy_model_material_paths :: proc(materials: map[i32]string) {
	for _, path in materials {delete(path)}
	delete(materials)
}
