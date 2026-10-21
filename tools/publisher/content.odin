package main

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "rune:pathutil"
import "rune:validation"

// Sources are absolute. Destinations use portable package-relative slash paths.
// The publisher runs with an arena; collected paths and diagnostics use it.
Publish_File :: struct {
	source, destination: string,
	// Empty-directory markers preserve explicitly included layouts. Nonempty
	// directories are created by their children and need no additional marker.
	directory: bool,
}

content_slashes :: proc(path: string) -> string {
	result, _ := strings.replace_all(path, "\\", "/")
	return result
}

publisher_path_is_within :: proc(root, path: string) -> bool {
	root := strings.trim_right(content_slashes(root), "/")
	path := strings.trim_right(content_slashes(path), "/")
	when ODIN_OS == .Windows {root = strings.to_lower(root); path = strings.to_lower(path)}
	return path == root || strings.has_prefix(path, fmt.aprintf("%s/", root))
}

// Check every ancestor, since lstat(target) alone can follow a linked parent.
// On Windows explicitly reject every reparse tag, including junctions and tags
// that the standard library does not identify as a symbolic link.
content_check_source_path :: proc(path: string) -> string {
	current, error := pathutil.absolute(path)
	if error != nil {return fmt.aprintf("cannot resolve path: %s (%v)", path, error)}
	for {
		info, stat_error := os.lstat(current, context.allocator)
		if stat_error != nil {return fmt.aprintf("cannot inspect path: %s (%v)", current, stat_error)}
		if info.type == .Symlink {return fmt.aprintf("symbolic links are not supported in publishing: %s", current)}
		if error := content_reparse_error(current); error != "" {return error}
		parent, _ := filepath.split(current)
		parent = strings.trim_right(parent, "/\\")
		when ODIN_OS == .Windows {if len(parent) == 2 && parent[1] == ':' {parent = fmt.aprintf("%s/", parent)}}
		if parent == "" || parent == current {break}
		current = parent
	}
	return ""
}

content_portable_segment :: proc(segment: string) -> bool {
	return !strings.contains_any(segment, "/\\") && config_content_path(segment)
}

content_relative_path :: proc(path: string) -> (string, string) {
	path := content_slashes(path)
	path = strings.trim_right(path, "/")
	if path == "" || strings.has_prefix(path, "/") {return "", "must be a non-empty project-relative path"}
	for segment in strings.split(path, "/") {
		if !content_portable_segment(segment) {return "", fmt.aprintf("invalid portable path segment: %s", segment)}
	}
	return path, ""
}

content_reserved :: proc(path, executable_name: string) -> bool {
	path := strings.to_lower(path)
	executable_name := strings.to_lower(executable_name)
	return path == "manifest.json" || strings.has_prefix(path, "manifest.json/") ||
	       path == "licenses/rune" || strings.has_prefix(path, "licenses/rune/") ||
	       path == executable_name || strings.has_prefix(path, fmt.aprintf("%s/", executable_name))
}

Content_Collector :: struct {
	files: [dynamic]Publish_File,
	// Track directories too: Foo/a and foo/b conflict even on Linux.
	destinations: map[string]string,
	spellings: map[string]string,
	executable_name: string,
}

content_add_path :: proc(collector: ^Content_Collector, source, destination: string, reserve := true) -> string {
	if error := content_check_source_path(source); error != "" {return error}
	if reserve && content_reserved(destination, collector.executable_name) {return fmt.aprintf("content uses publisher-reserved path: %s", destination)}
	// Explicit file includes can have shared ancestors without listing those
	// directories as includes; still enforce a single spelling for each parent.
	for i := 0; i <= len(destination); i += 1 {
		if i != len(destination) && destination[i] != '/' {continue}
		prefix := destination[:i]
		key := strings.to_lower(prefix)
		if original, found := collector.spellings[key]; found && original != prefix {return fmt.aprintf("case-conflicting package paths: %s and %s", original, prefix)}
		collector.spellings[key] = prefix
	}
	key := strings.to_lower(destination)
	if original, found := collector.destinations[key]; found {return fmt.aprintf("overlapping or case-conflicting package paths: %s and %s", original, destination)}
	collector.destinations[key] = destination
	info, error := os.lstat(source, context.allocator)
	if error != nil {return fmt.aprintf("cannot inspect content: %s (%v)", source, error)}
	if info.type == .Directory {
		entries, read_error := os.read_all_directory_by_path(source, context.allocator)
		if read_error != nil {return fmt.aprintf("cannot read content directory: %s (%v)", source, read_error)}
		if len(entries) == 0 {append(&collector.files, Publish_File{source=source, destination=destination, directory=true})}
		for entry in entries {
			if !content_portable_segment(entry.name) {return fmt.aprintf("content has non-portable filename: %s/%s", destination, entry.name)}
			child, _ := filepath.join({source, entry.name})
			child_destination := fmt.aprintf("%s/%s", destination, entry.name)
			if error := content_add_path(collector, child, child_destination, reserve); error != "" {return error}
		}
	} else if info.type == .Regular {
		append(&collector.files, Publish_File{source=source, destination=destination})
	} else {return fmt.aprintf("only regular files and directories may be published: %s", source)}
	return ""
}

collect_content :: proc(game_root: string, config: Config, executable_name: string) -> ([]Publish_File, string) {
	root, root_error := pathutil.absolute(game_root)
	if root_error != nil {return nil, fmt.aprintf("cannot resolve game root: %v", root_error)}
	collector := Content_Collector{files=make([dynamic]Publish_File), destinations=make(map[string]string), spellings=make(map[string]string), executable_name=executable_name}
	for paths in ([2][]string{config.content, config.licenses}) {
		for path in paths {
			relative, error := content_relative_path(path)
			if error != "" {return nil, fmt.aprintf("invalid publish include %q: %s", path, error)}
			source, _ := filepath.join({root, relative})
			if !publisher_path_is_within(root, source) {return nil, fmt.aprintf("include escapes game directory: %s", path)}
			if error := content_add_path(&collector, source, relative); error != "" {return nil, error}
		}
	}
	if destination, included := collector.destinations["project.json"]; !included || destination != "project.json" {return nil, "content must include project.json with that exact filename"}
	slice.sort_by(collector.files[:], proc(a, b: Publish_File) -> bool {return a.destination < b.destination})
	return collector.files[:], ""
}

copy_publish_files :: proc(files: []Publish_File, stage_root: string) -> string {
	for file in files {
		if error := content_check_source_path(file.source); error != "" {return error}
		target, _ := filepath.join({stage_root, file.destination})
		parent, _ := filepath.split(target)
		if error := os.make_directory_all(parent); error != nil && !os.is_directory(parent) {return fmt.aprintf("cannot create package directory: %s (%v)", parent, error)}
		if error := content_check_source_path(parent); error != "" {return error}
		if file.directory {
			info, error := os.lstat(file.source, context.allocator)
			if error != nil || info.type != .Directory {return fmt.aprintf("content is no longer a directory: %s", file.source)}
			if error := os.make_directory(target); error != nil {return fmt.aprintf("cannot create empty package directory: %s (%v)", target, error)}
			continue
		}
		source, open_error := os.open(file.source)
		if open_error != nil {return fmt.aprintf("cannot open content: %s (%v)", file.source, open_error)}
		info, stat_error := os.fstat(source, context.allocator)
		if stat_error != nil || info.type != .Regular {os.close(source); return fmt.aprintf("content is no longer a regular file: %s", file.source)}
		destination, create_error := os.open(target, {.Write, .Create, .Excl}, info.mode & os.Permissions_All)
		if create_error != nil {os.close(source); return fmt.aprintf("cannot create package file: %s (%v)", target, create_error)}
		_, copy_error := io.copy(os.to_writer(destination), os.to_reader(source))
		os.close(destination)
		os.close(source)
		if copy_error != nil {return fmt.aprintf("cannot copy package file: %s (%v)", target, copy_error)}
	}
	return ""
}

Content_Reference_Kind :: enum {File, Scene, Prefab, Material, Animation, Tileset, Terrain, Model}
Content_Reference :: struct {path: string, kind: Content_Reference_Kind}
Content_Scanner :: struct {
	root: string,
	files: map[string]string,
	pending: [dynamic]Content_Reference,
	visited: map[string]bool,
	scenes: [dynamic]string,
}

// Validate references against the staged file inventory, including exact case.
// Absolute authored references are never accepted, even if they still point to
// an existing file on the publishing machine. prefab:// is author-file-relative.
content_reference :: proc(scanner: ^Content_Scanner, author, field, value: string, kind := Content_Reference_Kind.File, relative_to_author := false, prefab_assets := false) -> string {
	if value == "" {return ""}
	relative_to_author := relative_to_author
	base := scanner.root
	path := content_slashes(value)
	if prefab_assets && strings.has_prefix(path, "prefab://") {path = path[len("prefab://"):]; relative_to_author = true}
	if strings.has_prefix(path, "/") || strings.contains(path, ":") {return fmt.aprintf("%s %s: absolute or external reference is not portable: %s", author, field, value)}
	if relative_to_author {directory, _ := filepath.split(author); base, _ = filepath.join({scanner.root, directory})}
	resolved, _ := filepath.join({base, path})
	if !publisher_path_is_within(scanner.root, resolved) {return fmt.aprintf("%s %s: reference escapes the package: %s", author, field, value)}
	relative := content_slashes(resolved)[len(strings.trim_right(content_slashes(scanner.root), "/"))+1:]
	exact, found := scanner.files[strings.to_lower(relative)]
	if !found {return fmt.aprintf("%s %s: referenced file is not included in publish content: %s", author, field, value)}
	if exact != relative {return fmt.aprintf("%s %s: reference case differs from packaged file %s: %s", author, field, exact, value)}
	if kind != .File {append(&scanner.pending, Content_Reference{relative, kind})}
	return ""
}

content_field_reference :: proc(scanner: ^Content_Scanner, author: string, object: json.Object, field: string, kind := Content_Reference_Kind.File, relative_to_author := false, prefab_assets := false) -> string {
	if value, present := object[field]; present {
		path, ok := value.(json.String)
		if !ok {return fmt.aprintf("%s %s: expected an asset path string", author, field)}
		return content_reference(scanner, author, field, path, kind, relative_to_author, prefab_assets)
	}
	return ""
}

content_scan_components :: proc(scanner: ^Content_Scanner, author: string, components: json.Object) -> string {
	for name, value in components {
		component, ok := value.(json.Object)
		if !ok {continue}
		field := ""
		kind := Content_Reference_Kind.File
		switch name {
		case "SpriteRenderer", "ParticleEmitter2D", "Skybox": field = "texture"
		case "TextRenderer": field = "font"
		case "ModelRenderer": field = "model"; kind = .Model
		case "SpriteAnimator": field = "animation"; kind = .Animation
		case "TilemapRenderer": field = "tileset"; kind = .Tileset
		case "Terrain": field = "asset"; kind = .Terrain
		case "NavMesh3D": field = "asset"
		case "ModelAnimator": field = "events"
		case "DirectionalLight", "PointLight", "SpotLight": field = "shadow_profile"
		case "AudioPlayer":
			for _, player_value in component {
				player, player_ok := player_value.(json.Object)
				if !player_ok {continue}
				if error := content_field_reference(scanner, author, player, "sound", prefab_assets=true); error != "" {return error}
				if clips, found := player["clips"].(json.Array); found {for clip in clips {if path, ok := clip.(json.String); ok {if error := content_reference(scanner, author, "AudioPlayer.clips", path, prefab_assets=true); error != "" {return error}}}}
			}
		}
		if field != "" {if error := content_field_reference(scanner, author, component, field, kind, prefab_assets=true); error != "" {return error}}
		if name == "ModelRenderer" {
			if error := content_field_reference(scanner, author, component, "material", .Material, prefab_assets=true); error != "" {return error}
			if materials, ok := component["materials"].(json.Object); ok {for _, material in materials {if path, ok := material.(json.String); ok {if error := content_reference(scanner, author, "materials", path, .Material, prefab_assets=true); error != "" {return error}}}}
		}
		if name == "TilemapRenderer" {if error := content_field_reference(scanner, author, component, "texture", prefab_assets=true); error != "" {return error}}
	}
	return ""
}

content_scan_entity :: proc(scanner: ^Content_Scanner, author: string, entity: json.Object) -> string {
	if error := content_field_reference(scanner, author, entity, "prefab", .Prefab, true); error != "" {return error}
	for field in ([2]string{"components", "component_overrides"}) {
		if components, ok := entity[field].(json.Object); ok {if error := content_scan_components(scanner, author, components); error != "" {return error}}
	}
	if overrides, ok := entity["child_overrides"].(json.Object); ok {for _, value in overrides {if override, ok := value.(json.Object); ok {if error := content_scan_entity(scanner, author, override); error != "" {return error}}}}
	if children, ok := entity["children"].(json.Array); ok {for value in children {if child, ok := value.(json.Object); ok {if error := content_scan_entity(scanner, author, child); error != "" {return error}}}}
	return ""
}

content_read_object :: proc(root, relative: string) -> (json.Object, string) {
	path, _ := filepath.join({root, relative})
	bytes, error := os.read_entire_file(path, context.allocator)
	if error != nil {return nil, fmt.aprintf("cannot read packaged JSON: %s (%v)", relative, error)}
	value: json.Value
	if json.unmarshal(bytes, &value) != nil {return nil, fmt.aprintf("invalid packaged JSON: %s", relative)}
	object, ok := value.(json.Object)
	if !ok {return nil, fmt.aprintf("expected a JSON object: %s", relative)}
	return object, ""
}

content_scan_document :: proc(scanner: ^Content_Scanner, reference: Content_Reference) -> string {
	if reference.kind == .Model {return content_scan_model(scanner, reference.path)}
	object, error := content_read_object(scanner.root, reference.path)
	if error != "" {return error}
	author := reference.path
	switch reference.kind {
	case .Scene:
		append(&scanner.scenes, author)
		if entities, ok := object["entities"].(json.Array); ok {for value in entities {if entity, ok := value.(json.Object); ok {if error := content_scan_entity(scanner, author, entity); error != "" {return error}}}}
	case .Prefab: return content_scan_entity(scanner, author, object)
	case .Material:
		for field in ([14]string{"surface_shader", "albedo", "texture", "normal", "emission", "emission_texture", "orm", "orm_texture", "roughness_texture", "metallic_texture", "ao_texture", "occlusion", "height_texture", "height"}) {
			if error := content_field_reference(scanner, author, object, field); error != "" {return error}
		}
	case .Animation, .Tileset: return content_field_reference(scanner, author, object, "texture")
	case .Terrain:
		if error := content_field_reference(scanner, author, object, "heightmap"); error != "" {return error}
		if error := content_field_reference(scanner, author, object, "material", .Material); error != "" {return error}
		if blend, ok := object["blend"].(json.Object); ok {for field in ([3]string{"grass", "dirt", "rock"}) {if path, ok := blend[field].(json.String); ok {kind := Content_Reference_Kind.File; if strings.has_suffix(strings.to_lower(path), ".json") {kind = .Material}; if error := content_reference(scanner, author, field, path, kind); error != "" {return error}}}}
		if maps, ok := object["control_maps"].(json.Array); ok {for value in maps {if path, ok := value.(json.String); ok {if error := content_reference(scanner, author, "control_maps", path); error != "" {return error}}}}
		for field in ([2]string{"layers", "details"}) {if entries, ok := object[field].(json.Array); ok {for value in entries {if entry, ok := value.(json.Object); ok {
			kind := Content_Reference_Kind.Material
			if material, ok := entry["material"].(json.String); ok && field == "layers" && !strings.has_suffix(strings.to_lower(material), ".json") {kind = .File}
			if error := content_field_reference(scanner, author, entry, "material", kind); error != "" {return error}
			if error := content_field_reference(scanner, author, entry, "model", .Model); error != "" {return error}
		}}}}
	case .File, .Model:
	}
	return ""
}

content_hex_digit :: proc(c: u8) -> (u8, bool) {
	if c >= '0' && c <= '9' {return c-'0', true}
	if c >= 'a' && c <= 'f' {return c-'a'+10, true}
	if c >= 'A' && c <= 'F' {return c-'A'+10, true}
	return 0, false
}

content_uri_path :: proc(uri: string) -> (string, string) {
	if strings.contains_any(uri, "?#") {return "", "URI query/fragment references are not supported"}
	bytes := make([dynamic]u8)
	for i := 0; i < len(uri); i += 1 {
		c := uri[i]
		if c == '%' {
			if i+2 >= len(uri) {return "", "invalid percent-encoded URI"}
			a, a_ok := content_hex_digit(uri[i+1]); b, b_ok := content_hex_digit(uri[i+2])
			if !a_ok || !b_ok {return "", "invalid percent-encoded URI"}
			c = a*16+b; i += 2
		}
		if c == 0 {return "", "NUL in URI"}
		append(&bytes, c)
	}
	return string(bytes[:]), ""
}

content_u32_le :: proc(bytes: []u8) -> u32 {return u32(bytes[0]) | u32(bytes[1])<<8 | u32(bytes[2])<<16 | u32(bytes[3])<<24}

content_scan_model :: proc(scanner: ^Content_Scanner, author: string) -> string {
	ext := strings.to_lower(filepath.ext(author))
	if ext != ".gltf" && ext != ".glb" && ext != ".obj" && ext != ".mtl" {return ""}
	path, _ := filepath.join({scanner.root, author})
	bytes, error := os.read_entire_file(path, context.allocator)
	if error != nil {return fmt.aprintf("cannot read model sidecars: %s (%v)", author, error)}
	if ext == ".gltf" || ext == ".glb" {
		if ext == ".glb" {
			if len(bytes) < 20 || string(bytes[:4]) != "glTF" || content_u32_le(bytes[4:8]) != 2 || u64(content_u32_le(bytes[8:12])) != u64(len(bytes)) || content_u32_le(bytes[16:20]) != 0x4e4f534a {return fmt.aprintf("invalid GLB header: %s", author)}
			length := u64(content_u32_le(bytes[12:16]))
			if length > u64(len(bytes)-20) {return fmt.aprintf("invalid GLB JSON chunk: %s", author)}
			bytes = bytes[20:20+int(length)]
		}
		value: json.Value
		if json.unmarshal(bytes, &value) != nil {return fmt.aprintf("invalid glTF JSON: %s", author)}
		object, ok := value.(json.Object)
		if !ok {return fmt.aprintf("invalid glTF object: %s", author)}
		for field in ([2]string{"buffers", "images"}) {if entries, ok := object[field].(json.Array); ok {for value in entries {if entry, ok := value.(json.Object); ok {if uri, ok := entry["uri"].(json.String); ok && !strings.has_prefix(uri, "data:") {
			path, error := content_uri_path(uri)
			if error != "" {return fmt.aprintf("%s %s: %s", author, field, error)}
			if error := content_reference(scanner, author, field, path, .File, true); error != "" {return error}
		}}}}}
		return ""
	}
	for raw_line in strings.split_lines(string(bytes)) {
		line := strings.trim_space(raw_line)
		separator := len(line)
		for c, i in line {if c == ' ' || c == '\t' {separator = i; break}}
		command := line[:separator]
		rest := strings.trim_space(line[separator:])
		if ext == ".obj" && command == "mtllib" {
			if error := content_reference(scanner, author, command, rest, .Model, true); error != "" {return error}
		}
		if ext == ".mtl" && (strings.has_prefix(command, "map_") || command == "bump" || command == "disp" || command == "decal" || command == "norm") {
			if strings.has_prefix(rest, "-") {return fmt.aprintf("%s %s: texture options require a reviewed plain sidecar path before publishing", author, command)}
			if error := content_reference(scanner, author, command, rest, .File, true); error != "" {return error}
		}
	}
	return ""
}

content_report_error :: proc(report: ^validation.Report) -> string {
	if validation.is_valid(report) {return ""}
	message := strings.builder_make()
	for diagnostic in report.diagnostics {fmt.sbprintf(&message, "%s %s: %s\n", diagnostic.file, diagnostic.path, diagnostic.message)}
	return strings.to_string(message)
}

validate_staged_project :: proc(stage_root: string) -> string {
	root, root_error := pathutil.absolute(stage_root)
	if root_error != nil {return fmt.aprintf("cannot resolve staging root: %v", root_error)}
	scanner := Content_Scanner{root=root, files=make(map[string]string), pending=make([dynamic]Content_Reference), visited=make(map[string]bool), scenes=make([dynamic]string)}
	collector := Content_Collector{files=make([dynamic]Publish_File), destinations=make(map[string]string), spellings=make(map[string]string)}
	entries, read_error := os.read_all_directory_by_path(root, context.allocator)
	if read_error != nil {return fmt.aprintf("cannot read staging directory: %v", read_error)}
	for entry in entries {path, _ := filepath.join({root, entry.name}); if error := content_add_path(&collector, path, entry.name, false); error != "" {return error}}
	for file in collector.files {if !file.directory {scanner.files[strings.to_lower(file.destination)] = file.destination}}
	project, error := content_read_object(root, "project.json")
	if error != "" {return error}
	if error := content_field_reference(&scanner, "project.json", project, "startup_scene", .Scene); error != "" {return error}
	if error := content_field_reference(&scanner, "project.json", project, "input"); error != "" {return error}
	// Explicitly named Rune documents are scanned even when only loaded by code.
	// Arbitrary JSON game data is not recursively interpreted as asset paths.
	for file in collector.files {
		if file.directory {continue}
		name := strings.to_lower(file.destination)
		kind := Content_Reference_Kind.File
		switch {
		case strings.has_suffix(name, ".scene.json"): kind = .Scene
		case strings.has_suffix(name, ".prefab.json"): kind = .Prefab
		case strings.has_suffix(name, ".material.json"): kind = .Material
		case strings.has_suffix(name, ".animation.json"): kind = .Animation
		case strings.has_suffix(name, ".tileset.json"): kind = .Tileset
		case strings.has_suffix(name, ".terrain.json"): kind = .Terrain
		case strings.has_suffix(name, ".obj"), strings.has_suffix(name, ".mtl"), strings.has_suffix(name, ".gltf"), strings.has_suffix(name, ".glb"): kind = .Model
		}
		if kind == .File && strings.has_suffix(name, ".json") && !strings.has_prefix(name, "schemas/") {
			// A scene is also recognizable without the conventional suffix. A
			// declared local Rune schema identifies other code-loaded documents.
			if object, error := content_read_object(root, file.destination); error == "" {
				if _, entities := object["entities"].(json.Array); entities {if _, named := object["name"].(json.String); named {kind = .Scene}}
				if schema, ok := object["$schema"].(json.String); ok {
					switch filepath.base(content_slashes(schema)) {
					case "scene.schema.json": kind = .Scene
					case "prefab.schema.json": kind = .Prefab
					case "material.schema.json": kind = .Material
					case "animation.schema.json": kind = .Animation
					case "tileset.schema.json": kind = .Tileset
					case "terrain.schema.json": kind = .Terrain
					}
				}
			}
		}
		if kind != .File {append(&scanner.pending, Content_Reference{file.destination, kind})}
	}
	for index := 0; index < len(scanner.pending); index += 1 {
		reference := scanner.pending[index]
		key := fmt.aprintf("%d:%s", reference.kind, reference.path)
		if scanner.visited[key] {continue}
		scanner.visited[key] = true
		if error := content_scan_document(&scanner, reference); error != "" {return error}
	}
	project_path, _ := filepath.join({root, "project.json"})
	report := validation.validate_project(project_path)
	report_error := content_report_error(&report)
	validation.destroy_report(&report)
	if report_error != "" {return report_error}
	for scene in scanner.scenes {
		path, _ := filepath.join({root, scene})
		scene_report := validation.validate_project_scene(project_path, path)
		error := content_report_error(&scene_report)
		validation.destroy_report(&scene_report)
		if error != "" {return error}
	}
	return ""
}
