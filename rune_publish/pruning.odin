package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "rune:pathutil"

Prune_Manifest_Record :: struct {path, sha256: string}
Prune_Report :: struct {
	enabled: bool,
	candidate_files, retained_files, pruned_files: int,
	candidate_bytes, retained_bytes, pruned_bytes: i64,
	roots, pruned: []string,
	manifests: []Prune_Manifest_Record,
}

Prune_State :: struct {
	scanner: Content_Scanner,
	candidates: []Publish_File,
	indices: map[string]int,
	roots: map[string]bool,
	retained: map[string]bool,
	dependencies: map[string][]string,
}

// Source metadata can live outside the content pool. Inspect each ancestor
// before descending, and compare directory entries even on case-folding hosts.
prune_checked_source :: proc(root, path: string) -> (string, string, string) {
	if !config_content_path(path) {return "", "", fmt.aprintf("invalid portable project-relative pruning path: %s", path)}
	relative := strings.trim_right(path, "/")
	current := root
	if error := content_check_source_path(current); error != "" {return "", "", error}
	for segment in strings.split(relative, "/") {
		entries, error := os.read_all_directory_by_path(current, context.allocator)
		if error != nil {return "", "", fmt.aprintf("cannot inspect pruning path %s: %v", path, error)}
		found, wrong_case := false, ""
		for entry in entries {
			if entry.name == segment {found = true; break}
			if strings.to_lower(entry.name) == strings.to_lower(segment) {wrong_case = entry.name}
		}
		if !found {
			if wrong_case != "" {return "", "", fmt.aprintf("pruning path case differs from source %s: %s", wrong_case, path)}
			return "", "", fmt.aprintf("pruning source does not exist: %s", path)
		}
		current, _ = filepath.join({current, segment})
		if error := content_check_source_path(current); error != "" {return "", "", error}
	}
	return relative, current, ""
}

// Digests for generated metadata include directory names as well as contents,
// so additions, removals, renames, and edits all invalidate a source-tree input.
// Directory paths must end in '/' and entries are relative to that directory.
prune_input_digest :: proc(root, path: string) -> (string, string) {
	relative, source, error := prune_checked_source(root, path)
	if error != "" {return "", error}
	info, stat_error := os.lstat(source, context.allocator)
	if stat_error != nil {return "", fmt.aprintf("cannot inspect pruning input %s: %v", path, stat_error)}
	if !strings.has_suffix(path, "/") {
		if info.type != .Regular {return "", fmt.aprintf("pruning input must name a regular file (directory inputs end in '/'): %s", path)}
		bytes, read_error := os.read_entire_file(source, context.allocator)
		if read_error != nil {return "", fmt.aprintf("cannot read pruning input %s: %v", path, read_error)}
		return hash_bytes(bytes), ""
	}
	if info.type != .Directory {return "", fmt.aprintf("pruning directory input must name a directory: %s", path)}
	collector := Content_Collector{files=make([dynamic]Publish_File), destinations=make(map[string]string), spellings=make(map[string]string)}
	if error := content_add_path(&collector, source, relative, false); error != "" {return "", error}
	slice.sort_by(collector.files[:], proc(a, b: Publish_File) -> bool {return a.destination < b.destination})
	data := strings.builder_make()
	for file in collector.files {
		if file.directory {continue}
		bytes, read_error := os.read_entire_file(file.source, context.allocator)
		if read_error != nil {return "", fmt.aprintf("cannot read pruning input %s: %v", file.destination, read_error)}
		fmt.sbprintf(&data, "%s%c%s\n", file.destination[len(relative)+1:], u8(0), hash_bytes(bytes))
	}
	text := strings.to_string(data)
	return hash_bytes(transmute([]u8)text), ""
}

prune_valid_digest :: proc(text: string) -> bool {
	if len(text) != 64 {return false}
	for c in text {if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return false}}
	return true
}

prune_string_paths :: proc(value: json.Value, location: string) -> ([]string, string) {
	array, ok := value.(json.Array)
	if !ok {return nil, fmt.aprintf("%s must be an array of project-relative file or directory paths", location)}
	result := make([]string, len(array))
	seen := make(map[string]bool)
	for raw, i in array {
		path, valid := raw.(json.String)
		if !valid || !config_content_path(path) {return nil, fmt.aprintf("%s[%d] must be a portable project-relative path", location, i)}
		relative := strings.trim_right(string(path), "/")
		key := strings.to_lower(relative)
		if seen[key] {return nil, fmt.aprintf("%s contains a duplicate or case-conflicting path: %s", location, path)}
		seen[key] = true
		result[i] = relative
	}
	return result, ""
}

// Every selected path must exist in the candidate inventory. Directories select
// their full subtree, including explicit empty-directory markers.
prune_select :: proc(state: ^Prune_State, path, author: string, root := false) -> string {
	if !config_content_path(path) {return fmt.aprintf("%s: invalid portable dependency path: %s", author, path)}
	path := strings.trim_right(path, "/")
	lower := strings.to_lower(path)
	if index, included := state.indices[lower]; included {
		file := state.candidates[index]
		if file.destination != path {return fmt.aprintf("%s: dependency case differs from included content %s: %s", author, file.destination, path)}
		if file.directory {state.retained[path] = true} else {append(&state.scanner.pending, Content_Reference{path, .File})}
		if root {state.roots[path] = true}
		return ""
	}
	found := false
	for file in state.candidates {
		name := file.destination
		key := strings.to_lower(name)
		if key != lower && !strings.has_prefix(key, fmt.aprintf("%s/", lower)) {continue}
		if name != path && !strings.has_prefix(name, fmt.aprintf("%s/", path)) {return fmt.aprintf("%s: dependency case differs from included content %s: %s", author, name, path)}
		found = true
		if file.directory {state.retained[name] = true} else {append(&state.scanner.pending, Content_Reference{name, .File})}
	}
	if !found {return fmt.aprintf("%s: dependency is not included in publish content: %s", author, path)}
	if root {state.roots[path] = true}
	return ""
}

prune_load_manifest :: proc(state: ^Prune_State, path: string) -> (Prune_Manifest_Record, string) {
	relative, source, error := prune_checked_source(state.scanner.root, path)
	if error != "" {return {}, error}
	info, stat_error := os.lstat(source, context.allocator)
	if stat_error != nil || info.type != .Regular {return {}, fmt.aprintf("pruning manifest must be a regular file: %s", path)}
	bytes, read_error := os.read_entire_file(source, context.allocator)
	if read_error != nil {return {}, fmt.aprintf("cannot read pruning manifest %s: %v", path, read_error)}
	if !config_json_syntax_valid(string(bytes)) {return {}, fmt.aprintf("pruning manifest %s must contain one strict JSON object", path)}
	value, parse_error := json.parse(bytes, spec=.JSON, parse_integers=true)
	if parse_error != nil {return {}, fmt.aprintf("invalid pruning manifest %s (duplicate keys are forbidden): %v", path, parse_error)}
	object, ok := value.(json.Object)
	if !ok {return {}, fmt.aprintf("pruning manifest %s must contain a JSON object", path)}
	if error := config_keys(object, {"version", "roots", "dependencies", "inputs"}, fmt.aprintf("pruning manifest %s", path)); error != "" {return {}, error}
	if version, ok := object["version"].(json.Integer); !ok || version != 1 {return {}, fmt.aprintf("pruning manifest %s version must be 1", path)}
	if raw, found := object["inputs"]; found {
		inputs, ok := raw.(json.Object)
		if !ok {return {}, fmt.aprintf("pruning manifest %s inputs must map source paths to lowercase SHA256 strings", path)}
		keys := make([dynamic]string)
		for key in inputs {append(&keys, key)}
		slice.sort(keys[:])
		seen := make(map[string]bool)
		for key in keys {
			digest, valid := inputs[key].(json.String)
			if !valid || !prune_valid_digest(digest) {return {}, fmt.aprintf("pruning manifest %s inputs.%s must be a lowercase SHA256 string", path, key)}
			folded := strings.to_lower(strings.trim_right(key, "/"))
			if seen[folded] {return {}, fmt.aprintf("pruning manifest %s has case-conflicting input paths: %s", path, key)}
			seen[folded] = true
			actual, digest_error := prune_input_digest(state.scanner.root, key)
			if digest_error != "" {return {}, fmt.aprintf("pruning manifest %s input %s: %s; regenerate the dependency manifest", path, key, digest_error)}
			if actual != digest {return {}, fmt.aprintf("pruning manifest %s input %s has changed; regenerate the dependency manifest", path, key)}
		}
	}
	if raw, found := object["roots"]; found {
		roots, error := prune_string_paths(raw, fmt.aprintf("pruning manifest %s roots", path))
		if error != "" {return {}, error}
		for entry in roots {if error := prune_select(state, entry, fmt.aprintf("pruning manifest %s roots", path), true); error != "" {return {}, error}}
	}
	if raw, found := object["dependencies"]; found {
		dependencies, ok := raw.(json.Object)
		if !ok {return {}, fmt.aprintf("pruning manifest %s dependencies must map candidate file paths to arrays of dependency paths", path)}
		keys := make([dynamic]string)
		for key in dependencies {append(&keys, key)}
		slice.sort(keys[:])
		for key in keys {
			if !config_content_path(key) || strings.has_suffix(key, "/") {return {}, fmt.aprintf("pruning manifest %s dependency source must be a portable candidate file path: %s", path, key)}
			index, included := state.indices[strings.to_lower(key)]
			if !included || state.candidates[index].directory {return {}, fmt.aprintf("pruning manifest %s dependency source is not an included file: %s", path, key)}
			if state.candidates[index].destination != key {return {}, fmt.aprintf("pruning manifest %s dependency source case differs from included file %s: %s", path, state.candidates[index].destination, key)}
			entries, error := prune_string_paths(dependencies[key], fmt.aprintf("pruning manifest %s dependencies.%s", path, key))
			if error != "" {return {}, error}
			existing := make([dynamic]string)
			append(&existing, ..state.dependencies[key])
			append(&existing, ..entries)
			state.dependencies[key] = existing[:]
		}
	}
	return Prune_Manifest_Record{relative, hash_bytes(bytes)}, ""
}

prune_content :: proc(game_root: string, config: Config, files: []Publish_File) -> ([]Publish_File, Prune_Report, string) {
	if !config.prune.enabled {return files, {}, ""}
	root, root_error := pathutil.absolute(game_root)
	if root_error != nil {return nil, {}, fmt.aprintf("cannot resolve pruning root: %v", root_error)}
	state := Prune_State{
		scanner=Content_Scanner{root=root, files=make(map[string]string), pending=make([dynamic]Content_Reference), visited=make(map[string]bool), scenes=make([dynamic]string), pruning=true},
		candidates=files, indices=make(map[string]int), roots=make(map[string]bool), retained=make(map[string]bool), dependencies=make(map[string][]string),
	}
	report := Prune_Report{enabled=true}
	for file, i in files {
		state.indices[strings.to_lower(file.destination)] = i
		if file.directory {continue}
		state.scanner.files[strings.to_lower(file.destination)] = file.destination
		if error := content_check_source_path(file.source); error != "" {return nil, {}, error}
		info, error := os.lstat(file.source, context.allocator)
		if error != nil || info.type != .Regular {return nil, {}, fmt.aprintf("cannot inspect pruning candidate: %s", file.destination)}
		report.candidate_files += 1
		report.candidate_bytes += info.size
	}
	if error := prune_select(&state, "project.json", "pruning project root", true); error != "" {return nil, {}, error}
	for path in config.prune.roots {if error := prune_select(&state, path, "publish.json prune.roots", true); error != "" {return nil, {}, error}}
	for path in config.licenses {if error := prune_select(&state, path, "publish.json licenses", true); error != "" {return nil, {}, error}}
	manifests := make([dynamic]Prune_Manifest_Record)
	seen_manifests := make(map[string]bool)
	for path in config.prune.manifests {
		key := strings.to_lower(path)
		if seen_manifests[key] {return nil, {}, fmt.aprintf("duplicate or case-conflicting pruning manifest: %s", path)}
		seen_manifests[key] = true
		record, error := prune_load_manifest(&state, path)
		if error != "" {return nil, {}, error}
		append(&manifests, record)
	}
	for index := 0; index < len(state.scanner.pending); index += 1 {
		reference := state.scanner.pending[index]
		state.retained[reference.path] = true
		key := fmt.aprintf("%d:%s", reference.kind, reference.path)
		if state.scanner.visited[key] {continue}
		state.scanner.visited[key] = true
		if error := content_scan_document(&state.scanner, reference); error != "" {return nil, {}, error}
		// Apply custom data edges only after the source becomes reachable.
		for dependency in state.dependencies[reference.path] {if error := prune_select(&state, dependency, fmt.aprintf("dependency of %s", reference.path)); error != "" {return nil, {}, error}}
	}
	retained := make([dynamic]Publish_File)
	pruned := make([dynamic]string)
	for file in files {
		if state.retained[file.destination] {
			append(&retained, file)
			if !file.directory {
				info, error := os.lstat(file.source, context.allocator)
				if error != nil || info.type != .Regular {return nil, {}, fmt.aprintf("cannot inspect retained pruning file: %s", file.destination)}
				report.retained_files += 1
				report.retained_bytes += info.size
			}
		} else if !file.directory {append(&pruned, file.destination)}
	}
	roots := make([dynamic]string)
	for path in state.roots {append(&roots, path)}
	slice.sort(roots[:])
	slice.sort(pruned[:])
	slice.sort_by(retained[:], proc(a, b: Publish_File) -> bool {return a.destination < b.destination})
	slice.sort_by(manifests[:], proc(a, b: Prune_Manifest_Record) -> bool {return a.path < b.path})
	report.roots, report.pruned, report.manifests = roots[:], pruned[:], manifests[:]
	report.pruned_files = report.candidate_files-report.retained_files
	report.pruned_bytes = report.candidate_bytes-report.retained_bytes
	return retained[:], report, ""
}
