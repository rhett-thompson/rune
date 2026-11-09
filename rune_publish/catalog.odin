package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "rune:pathutil"

Asset_Catalog_Filename :: "assets.json"

Content_Plan :: struct {
	files: []Publish_File,
	directories: []string,
	catalog_sha256: string,
}

Catalog_Planner :: struct {
	scanner: Content_Scanner,
	directories: map[string]bool,
	dependencies: map[string][]string,
}

Catalog_Path_Kind :: enum {Either, File, Directory}

catalog_include_path :: proc(planner: ^Catalog_Planner, path, label: string, kind := Catalog_Path_Kind.Either) -> string {
	if kind == .File && strings.has_suffix(path, "/") {return fmt.aprintf("%s must name a regular file: %s", label, path)}
	relative, source, error := content_resolve_source(planner.scanner.root, path)
	if error != "" {return fmt.aprintf("%s: %s", label, error)}
	info, stat_error := os.lstat(source, context.allocator)
	if stat_error != nil {return fmt.aprintf("%s: cannot inspect %s (%v)", label, path, stat_error)}
	#partial switch info.type {
	case .Regular:
		if kind == .Directory || strings.has_suffix(path, "/") {return fmt.aprintf("%s must name a directory: %s", label, path)}
	case .Directory:
		if kind == .File {return fmt.aprintf("%s must name a regular file: %s", label, path)}
		if planner.directories[relative] {return ""}
		planner.directories[relative] = true
	case:
		return fmt.aprintf("%s must name a regular file or directory: %s", label, path)
	}
	collector := planner.scanner.collector
	first_new_file := len(collector.files)
	if error := content_add_path(collector, source, relative, allow_existing=true); error != "" {
		return fmt.aprintf("%s: %s", label, error)
	}
	for file in collector.files[first_new_file:] {
		if !file.directory {append(&planner.scanner.pending, Content_Reference{file.destination, .File})}
	}
	return ""
}

// Preserve the documented digest format for source inputs. Directory hashes
// include every relative filename and file hash in sorted order.
catalog_input_digest :: proc(root, path: string) -> (string, string) {
	relative, source, error := content_resolve_source(root, path)
	if error != "" {return "", error}
	info, stat_error := os.lstat(source, context.allocator)
	if stat_error != nil {return "", fmt.aprintf("cannot inspect catalog input %s: %v", path, stat_error)}
	if !strings.has_suffix(path, "/") {
		if info.type != .Regular {return "", fmt.aprintf("catalog input must name a regular file (directory inputs end in '/'): %s", path)}
		return hash_file(source)
	}
	if info.type != .Directory {return "", fmt.aprintf("catalog directory input must name a directory: %s", path)}
	collector := Content_Collector{files=make([dynamic]Publish_File), destinations=make(map[string]string), spellings=make(map[string]string)}
	if error := content_add_path(&collector, source, relative, false); error != "" {return "", error}
	slice.sort_by(collector.files[:], proc(a, b: Publish_File) -> bool {return a.destination < b.destination})
	data := strings.builder_make()
	for file in collector.files {
		if file.directory {continue}
		digest, error := hash_file(file.source)
		if error != "" {return "", error}
		fmt.sbprintf(&data, "%s%c%s\n", file.destination[len(relative)+1:], u8(0), digest)
	}
	return hash_bytes(transmute([]u8)strings.to_string(data)), ""
}

catalog_valid_digest :: proc(text: string) -> bool {
	if len(text) != 64 {return false}
	for c in text {if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return false}}
	return true
}

catalog_sorted_keys :: proc(object: json.Object) -> []string {
	keys := make([dynamic]string, 0, len(object))
	for key in object {append(&keys, key)}
	slice.sort(keys[:])
	return keys[:]
}

catalog_check_inputs :: proc(root: string, value: json.Value) -> string {
	inputs, ok := value.(json.Object)
	if !ok {return "assets.json inputs must map source paths to lowercase SHA256 strings"}
	seen := make(map[string]bool)
	for key in catalog_sorted_keys(inputs) {
		digest, valid := inputs[key].(json.String)
		if !valid || !catalog_valid_digest(digest) {return fmt.aprintf("assets.json inputs.%s must be a lowercase SHA256 string", key)}
		folded := strings.to_lower(strings.trim_right(key, "/"))
		if seen[folded] {return fmt.aprintf("assets.json has case-conflicting input paths: %s", key)}
		seen[folded] = true
		actual, error := catalog_input_digest(root, key)
		if error != "" {return fmt.aprintf("assets.json input %s: %s; regenerate the asset catalog", key, error)}
		if actual != digest {return fmt.aprintf("assets.json input %s has changed; regenerate the asset catalog", key)}
	}
	return ""
}

catalog_name_valid :: proc(name: string) -> bool {
	if name == "" || name != strings.trim_space(name) || strings.contains_any(name, "/\\:") {return false}
	for c in name {if c < 32 || c == 127 {return false}}
	return true
}

catalog_load_names :: proc(planner: ^Catalog_Planner, object: json.Object) -> string {
	names := make(map[string]bool)
	for field in ([]string{"assets", "directories"}) {
		raw, present := object[field]
		if !present && field == "directories" {continue}
		entries, valid := raw.(json.Object)
		if !valid {return fmt.aprintf("assets.json %s must map names to paths", field)}
		kind := Catalog_Path_Kind.File if field == "assets" else Catalog_Path_Kind.Directory
		for name in catalog_sorted_keys(entries) {
			entry, valid := entries[name].(json.String)
			if !catalog_name_valid(name) || !valid {return fmt.aprintf("assets.json %s has an invalid entry: %q", field, name)}
			if names[name] {return fmt.aprintf("assets.json repeats asset/directory name: %s", name)}
			names[name] = true
			label := fmt.aprintf("assets.json %s.%s", field, name)
			if error := catalog_include_path(planner, entry, label, kind); error != "" {return error}
		}
	}
	return ""
}

catalog_load_dependencies :: proc(planner: ^Catalog_Planner, value: json.Value) -> string {
	dependencies, ok := value.(json.Object)
	if !ok {return "assets.json dependencies must map file paths to arrays of dependency paths"}
	for key in catalog_sorted_keys(dependencies) {
		label := fmt.aprintf("assets.json dependencies.%s", key)
		if strings.has_suffix(key, "/") {return fmt.aprintf("%s must name a regular file", label)}
		relative, source, error := content_resolve_source(planner.scanner.root, key)
		if error != "" {return fmt.aprintf("%s: %s", label, error)}
		info, stat_error := os.lstat(source, context.allocator)
		if stat_error != nil || info.type != .Regular {return fmt.aprintf("%s must name a regular file", label)}
		paths, path_error := config_path_array(dependencies[key], label)
		if path_error != "" {return path_error}
		seen := make(map[string]bool)
		for path in paths {
			folded := strings.to_lower(strings.trim_right(path, "/"))
			if seen[folded] {return fmt.aprintf("%s contains a duplicate or case-conflicting path: %s", label, path)}
			seen[folded] = true
		}
		planner.dependencies[relative] = paths
	}
	return ""
}

catalog_load :: proc(planner: ^Catalog_Planner) -> (string, string) {
	if error := catalog_include_path(planner, Asset_Catalog_Filename, "asset catalog", .File); error != "" {return "", error}
	path, _ := filepath.join({planner.scanner.root, Asset_Catalog_Filename})
	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return "", fmt.aprintf("cannot read assets.json: %v", read_error)}
	if !config_json_syntax_valid(string(bytes)) {return "", "assets.json must contain one strict JSON object"}
	value, parse_error := json.parse(bytes, spec=.JSON, parse_integers=true)
	if parse_error != nil {return "", fmt.aprintf("invalid assets.json (duplicate keys are forbidden): %v", parse_error)}
	object, ok := value.(json.Object)
	if !ok {return "", "assets.json must contain a JSON object"}
	if error := config_keys(object, {"$schema", "version", "assets", "directories", "dependencies", "inputs"}, Asset_Catalog_Filename); error != "" {return "", error}
	if version, ok := object["version"].(json.Integer); !ok || version != 1 {return "", "assets.json version must be 1"}
	if schema, found := object["$schema"]; found {
		if _, ok := schema.(json.String); !ok {return "", "assets.json $schema must be a string"}
	}
	if error := catalog_load_names(planner, object); error != "" {return "", error}
	if raw, found := object["inputs"]; found {
		if error := catalog_check_inputs(planner.scanner.root, raw); error != "" {return "", error}
	}
	if raw, found := object["dependencies"]; found {
		if error := catalog_load_dependencies(planner, raw); error != "" {return "", error}
	}
	return hash_bytes(bytes), ""
}

plan_content :: proc(game_root: string, config: Config, executable_name: string) -> (Content_Plan, string) {
	root, root_error := pathutil.absolute(game_root)
	if root_error != nil {return {}, fmt.aprintf("cannot resolve game directory: %v", root_error)}
	collector := Content_Collector{files=make([dynamic]Publish_File), destinations=make(map[string]string), spellings=make(map[string]string), executable_name=executable_name}
	planner := Catalog_Planner{
		scanner=Content_Scanner{root=root, collector=&collector, pending=make([dynamic]Content_Reference), visited=make(map[string]bool), scenes=make([dynamic]string)},
		directories=make(map[string]bool), dependencies=make(map[string][]string),
	}
	if error := catalog_include_path(&planner, "project.json", "project descriptor", .File); error != "" {return {}, error}
	digest, error := catalog_load(&planner)
	if error != "" {return {}, error}
	for path in config.licenses {
		if error := catalog_include_path(&planner, path, "publish.json licenses"); error != "" {return {}, error}
	}
	for index := 0; index < len(planner.scanner.pending); index += 1 {
		reference := planner.scanner.pending[index]
		key := fmt.aprintf("%d:%s", reference.kind, reference.path)
		if planner.scanner.visited[key] {continue}
		planner.scanner.visited[key] = true
		if error := content_scan_document(&planner.scanner, reference); error != "" {return {}, error}
		// Expand each custom edge list once, after its source becomes reachable.
		if paths, found := planner.dependencies[reference.path]; found {
			delete_key(&planner.dependencies, reference.path)
			for path in paths {
				label := fmt.aprintf("assets.json dependency of %s", reference.path)
				if error := catalog_include_path(&planner, path, label); error != "" {return {}, error}
			}
		}
	}
	directories := make([dynamic]string, 0, len(planner.directories))
	for path in planner.directories {append(&directories, path)}
	slice.sort(directories[:])
	slice.sort_by(collector.files[:], proc(a, b: Publish_File) -> bool {return a.destination < b.destination})
	return Content_Plan{files=collector.files[:], directories=directories[:], catalog_sha256=digest}, ""
}
