package prefab

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Resolution uses caller-owned scratch storage. The input JSON is never mutated.
// Objects merge only through component_overrides; legacy components replace blocks.
Resolution :: struct {
	value: json.Value,
	dependencies: [dynamic]string,
	error: string,
}

Resolver :: struct {
	allocator: mem.Allocator,
	result: Resolution,
	stack: [dynamic]string,
}

Node :: struct {
	data: json.Object,
	children: [dynamic]Node,
	local_id: bool,
}

resolve_scene :: proc(value: json.Value, file: string, allocator := context.allocator) -> Resolution {
	r := Resolver{allocator = allocator}
	r.result.dependencies = make([dynamic]string, allocator)
	r.stack = make([dynamic]string, allocator)
	append(&r.result.dependencies, file)
	root, valid := json.clone_value(value, allocator).(json.Object)
	if !valid {fail(&r, file, "scene must be an object"); return r.result}
	entities, ok := root["entities"].(json.Array)
	if !ok {fail(&r, file, "entities must be an array"); return r.result}
	resolved := make(json.Array, 0, len(entities), allocator)
	for entity in entities {
		node := expand(&r, entity, file, false, 0)
		if r.result.error != "" {return r.result}
		append(&resolved, emit(&r, node, "", nil, false, file))
		if r.result.error != "" {return r.result}
	}
	root["entities"] = resolved
	r.result.value = root
	return r.result
}

fail :: proc(r: ^Resolver, file, message: string) {
	if r.result.error == "" {r.result.error = fmt.aprintf("%s: %s", file, message, allocator = r.allocator)}
}

absolute_path :: proc(r: ^Resolver, file, reference: string) -> string {
	directory, _ := filepath.split(file)
	path := reference
	if !filepath.is_abs(path) {path, _ = filepath.join({directory, path}, r.allocator)}
	absolute, err := filepath.abs(path, r.allocator)
	if err != nil {fail(r, file, "could not resolve path"); return ""}
	return absolute
}

expand :: proc(r: ^Resolver, value: json.Value, file: string, local: bool, depth: int) -> Node {
	if depth > 64 {fail(r, file, "prefab/entity nesting exceeds 64 levels"); return {}}
	authored, ok := value.(json.Object)
	if !ok {fail(r, file, "entity must be an object"); return {}}
	node := Node{data = make(json.Object, r.allocator), children = make([dynamic]Node, r.allocator), local_id = local}
	if reference_value, present := authored["prefab"]; present {
		reference, valid := reference_value.(json.String)
		if !valid || reference == "" {fail(r, file, "prefab must be a non-empty path"); return node}
		path := absolute_path(r, file, reference)
		for active in r.stack {
			when ODIN_OS == .Windows {
				cyclic := strings.to_lower(active, r.allocator) == strings.to_lower(path, r.allocator)
			} else {
				cyclic := active == path
			}
			if cyclic {fail(r, file, fmt.tprintf("cyclic prefab reference to '%s'", path)); return node}
		}
		data, err := os.read_entire_file(path, r.allocator)
		if err != nil {fail(r, file, fmt.tprintf("could not read prefab '%s'", path)); return node}
		base: json.Value
		if json.unmarshal(data, &base, allocator = r.allocator) != nil {fail(r, path, "invalid prefab JSON"); return node}
		base_object, object_ok := base.(json.Object)
		if !object_ok {fail(r, path, "prefab must be an object"); return node}
		name, name_ok := base_object["name"].(json.String)
		if !name_ok || name == "" {fail(r, path, "prefab name must be a non-empty string"); return node}
		if _, has_components := base_object["components"]; !has_components {
			if _, has_base := base_object["prefab"]; !has_base {fail(r, path, "prefab requires components or a base prefab"); return node}
		}
		// Preserve dependency occurrences for compatibility with existing callers.
		append(&r.result.dependencies, path)
		append(&r.stack, path)
		node = expand(r, base, path, true, depth+1)
		pop(&r.stack)
		if r.result.error != "" {return node}
		// A prefab root ID is local to its owner, never the instance's ID.
		delete_key(&node.data, "id")
		node.local_id = local
	}
	for key, entry in authored {
		if key == "$schema" || key == "prefab" || key == "children" || key == "components" ||
		   key == "component_overrides" || key == "remove_components" || key == "child_overrides" {continue}
		node.data[key] = json.clone_value(entry, r.allocator)
	}
	apply_components(r, &node, authored, file)
	if children_value, present := authored["children"]; present {
		children, valid := children_value.(json.Array)
		if !valid {fail(r, file, "children must be an array"); return node}
		for child in children {append(&node.children, expand(r, child, file, local, depth+1))}
	}
	ids := make(map[string]bool, r.allocator)
	for child in node.children {
		if id_value, present := child.data["id"]; present {
			id, valid := id_value.(json.String)
			if !valid || id == "" || (child.local_id && strings.contains(id, "/")) {
				fail(r, file, "prefab child IDs must be non-empty local names without '/'"); return node
			}
			if ids[id] {fail(r, file, fmt.tprintf("duplicate child ID '%s'", id)); return node}
			ids[id] = true
		}
	}
	apply_children(r, &node, authored, file, depth)
	return node
}

apply_components :: proc(r: ^Resolver, node: ^Node, patch: json.Object, file: string) {
	components, _ := node.data["components"].(json.Object)
	if components == nil {components = make(json.Object, r.allocator)}
	if value, present := patch["components"]; present {
		blocks, ok := value.(json.Object)
		if !ok {fail(r, file, "components must be an object"); return}
		for name, block in blocks {
			if _, valid := block.(json.Object); !valid {fail(r, file, fmt.tprintf("component '%s' must be an object", name)); return}
			components[name] = resolve_assets(r, block, file)
		}
	}
	if value, present := patch["component_overrides"]; present {
		blocks, ok := value.(json.Object)
		if !ok {fail(r, file, "component_overrides must be an object"); return}
		for name, block in blocks {
			base, exists := components[name]
			if !exists {fail(r, file, fmt.tprintf("cannot override missing component '%s'", name)); return}
			if _, valid := block.(json.Object); !valid {fail(r, file, "component overrides must be objects"); return}
			components[name] = merge_fields(r, base, resolve_assets(r, block, file))
		}
	}
	if value, present := patch["remove_components"]; present {
		names, ok := value.(json.Array)
		if !ok {fail(r, file, "remove_components must be an array"); return}
		for entry in names {
			name, valid := entry.(json.String)
			if !valid || name == "" {fail(r, file, "remove_components entries must be non-empty strings"); return}
			if _, exists := components[name]; !exists {fail(r, file, fmt.tprintf("cannot remove missing component '%s'", name)); return}
			delete_key(&components, name)
		}
	}
	node.data["components"] = components
}

merge_fields :: proc(r: ^Resolver, base, patch: json.Value) -> json.Value {
	a, a_ok := base.(json.Object)
	b, b_ok := patch.(json.Object)
	if !a_ok || !b_ok {return json.clone_value(patch, r.allocator)}
	result := json.clone_value(base, r.allocator).(json.Object)
	for key, value in b {
		if old, exists := a[key]; exists {result[key] = merge_fields(r, old, value)}
		else {result[key] = json.clone_value(value, r.allocator)}
	}
	return result
}

apply_children :: proc(r: ^Resolver, node: ^Node, patch: json.Object, file: string, depth: int) {
	if depth > 64 {fail(r, file, "child override nesting exceeds 64 levels"); return}
	value, present := patch["child_overrides"]
	if !present {return}
	entries, ok := value.(json.Object)
	if !ok {fail(r, file, "child_overrides must be an object keyed by child ID paths"); return}
	key_list := make([dynamic]string, r.allocator)
	for key in entries {append(&key_list, key)}
	keys := key_list[:]
	slice.sort(keys)
	// Parents sort before descendants, making overlapping patches deterministic.
	for path in keys {
		target := find_child(node, path)
		if target == nil {fail(r, file, fmt.tprintf("child_overrides target '%s' does not exist", path)); return}
		fields, valid := entries[path].(json.Object)
		if !valid {fail(r, file, "child override must be an object"); return}
		for key, entry in fields {
			switch key {
			case "enabled", "name", "tag", "layers": target.data[key] = json.clone_value(entry, r.allocator)
			case "components", "component_overrides", "remove_components", "child_overrides":
			case: fail(r, file, fmt.tprintf("unsupported child override field '%s'", key)); return
			}
		}
		apply_components(r, target, fields, file)
		apply_children(r, target, fields, file, depth+1)
		if r.result.error != "" {return}
	}
}

find_child :: proc(node: ^Node, path: string) -> ^Node {
	if path == "" {return nil}
	part, separator, rest := strings.partition(path, "/")
	for &child in node.children {
		id, _ := child.data["id"].(json.String)
		if id != part {continue}
		if separator == "" {return &child}
		return find_child(&child, rest)
	}
	return nil
}

emit :: proc(r: ^Resolver, node: Node, prefix: string, inherited_layers: json.Value, local: bool, file: string) -> json.Value {
	node := node
	id, _ := node.data["id"].(json.String)
	if local && id != "" {
		if prefix == "" {fail(r, file, "named prefab children require IDs on the instance and every ancestor"); return nil}
		id = fmt.aprintf("%s/%s", prefix, id, allocator = r.allocator)
		node.data["id"] = id
	}
	if local {
		if _, present := node.data["layers"]; !present && inherited_layers != nil {node.data["layers"] = inherited_layers}
	}
	children := make(json.Array, 0, len(node.children), r.allocator)
	for child in node.children {append(&children, emit(r, child, id, node.data["layers"], child.local_id, file))}
	node.data["children"] = children
	return node.data
}

// Explicit prefix keeps existing project-relative strings backward compatible.
// Resolve at the authoring file before merging, including custom component data.
resolve_assets :: proc(r: ^Resolver, value: json.Value, file: string) -> json.Value {
	#partial switch v in value {
	case json.String:
		if strings.has_prefix(v, "prefab://") {
			if len(v) == len("prefab://") {fail(r, file, "prefab:// requires a relative asset path"); return value}
			return absolute_path(r, file, v[len("prefab://"):])
		}
		return json.clone_value(value, r.allocator)
	case json.Object:
		result := make(json.Object, r.allocator)
		for key, entry in v {result[key] = resolve_assets(r, entry, file)}
		return result
	case json.Array:
		result := make(json.Array, 0, len(v), r.allocator)
		for entry in v {append(&result, resolve_assets(r, entry, file))}
		return result
	case: return value
	}
}
