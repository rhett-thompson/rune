package prefab

import "core:encoding/json"
import "core:mem"
import "core:os"

// Entity_Data is the reusable portion of an entity definition. Instance-only
// metadata such as IDs, tags, and layers stays in the scene that instantiates it.
Entity_Data :: struct {
	enabled: Maybe(bool),
	name:       string,
	components: map[string]json.Value,
	children:   []Entity_Data,
}

Prefab :: struct {
	enabled: Maybe(bool),
	name:       string,
	components: map[string]json.Value,
	children:   []Entity_Data,
}

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
