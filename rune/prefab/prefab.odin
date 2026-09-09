package prefab

import "core:encoding/json"
import "core:mem"
import "core:os"

// Child IDs are local path segments. The scene resolver qualifies them with
// their containing instance's ID, e.g. player/camera. load returns authored data;
// resolve_scene expands references and applies overrides.
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

Prefab :: Entity_Data

load :: proc(path: string, allocator := context.allocator) -> (Prefab, bool) {
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {return {}, false}
	prefab: Prefab
	if json.unmarshal(data, &prefab, allocator = allocator) != nil {return {}, false}
	return prefab, true
}

// merge_components applies instance component blocks over a prefab's defaults.
// Replacing an individual component block keeps the first prefab slice simple
// and avoids ambiguous deep-merge rules for arbitrary custom component data.
merge_components :: proc(
	base, overrides: map[string]json.Value,
	allocator: mem.Allocator = context.allocator,
) -> map[string]json.Value {
	result := make(map[string]json.Value, allocator)
	for name, data in base {result[name] = data}
	for name, data in overrides {result[name] = data}
	return result
}
