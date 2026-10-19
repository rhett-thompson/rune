package assets

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
model_material_defaults_parse_slot_paths_and_reject_invalid_data :: proc(t: ^testing.T) {
	value: json.Value
	document: string = `{"materials":{"0":"materials/a.json","3":"materials/b.json"}}`
	testing.expect(t, json.unmarshal(transmute([]u8)document, &value) == nil)
	defer json.destroy_value(value)
	paths, ok := model_material_paths_from_json(value)
	defer destroy_model_material_paths(paths)
	testing.expect(t, ok && len(paths) == 2 && paths[0] == "materials/a.json" && paths[3] == "materials/b.json")
	invalid_documents := []string{
		`{}`, `{"materials":[]}`, `{"materials":{"-1":"materials/a.json"}}`,
		`{"materials":{"2147483648":"materials/a.json"}}`,
		`{"materials":{"0":""}}`, `{"materials":{"0":13}}`,
		`{"materials":{"0":"materials/a.json","00":"materials/b.json"}}`,
	}
	for invalid_document in invalid_documents {
		invalid: json.Value
		if !testing.expect(t, json.unmarshal(transmute([]u8)invalid_document, &invalid) == nil) {continue}
		parsed, parsed_ok := model_material_paths_from_json(invalid)
		testing.expect(t, !parsed_ok, invalid_document)
		destroy_model_material_paths(parsed)
		json.destroy_value(invalid)
	}
}

@(test)
model_material_defaults_watch_creation_replace_invalid_and_removal :: proc(t: ^testing.T) {
	file, error := os.create_temp_file("", "rune-model-materials-*.obj")
	if !testing.expect(t, error == nil) {return}
	model, _ := strings.clone(os.name(file))
	defer delete(model)
	testing.expect(t, os.close(file) == nil)
	defer os.remove(model)
	sidecar := fmt.aprintf("%s.materials.json", model)
	defer delete(sidecar)
	defer os.remove(sidecar)
	manager := material_preview_test_manager()
	defer shutdown(&manager)
	testing.expect(t, len(model_material_paths(&manager, model)) == 0)
	testing.expect(t, len(manager.diagnostics.pending) == 0, "absent optional sidecars are quiet")
	testing.expect(t, os.write_entire_file(sidecar, `{"materials":{"0":"materials/first.json"}}`) == nil)
	refresh_materials(&manager)
	testing.expect(t, model_material_path(&manager, model, 0) == "materials/first.json")
	revision := material_asset_revision(&manager)
	testing.expect(t, revision == 2, "sidecar creation invalidates existing renderer and instance caches")
	testing.expect(t, os.write_entire_file(sidecar, `{"materials":{"0":false}}`) == nil)
	// Force a distinct observed time rather than relying on filesystem resolution.
	cached := manager.model_materials[model]; cached.modified_time = -2; manager.model_materials[model] = cached
	refresh_materials(&manager)
	testing.expect(t, model_material_path(&manager, model, 0) == "materials/first.json")
	testing.expect(t, material_asset_revision(&manager) == revision, "invalid replacements retain the working material")
	testing.expect(t, os.write_entire_file(sidecar, `{"materials":{"0":"materials/second.json"}}`) == nil)
	cached = manager.model_materials[model]; cached.modified_time = -2; manager.model_materials[model] = cached
	refresh_materials(&manager)
	testing.expect(t, model_material_path(&manager, model, 0) == "materials/second.json")
	testing.expect(t, material_asset_revision(&manager) == revision + 1)
	testing.expect(t, os.remove(sidecar) == nil)
	refresh_materials(&manager)
	testing.expect(t, model_material_path(&manager, model, 0) == "")
	testing.expect(t, material_asset_revision(&manager) == revision + 2, "removing the sidecar restores unassigned slots")
}
