package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// Config and its nested data use context.allocator. The publisher keeps them in
// its invocation arena; no returned strings borrow the source byte buffer.
Config :: struct {
	id, name, version, executable: string,
	targets, content, licenses: []string,
	build: Build_Settings,
	prune: Prune_Settings,
}

Prune_Settings :: struct {
	enabled: bool,
	roots, manifests: []string,
}

Build_Settings :: struct {
	collections: map[string]string,
	defines: map[string]json.Value,
	extra_linker_flags: string,
}

load_config :: proc(path: string) -> (Config, string) {
	bytes, error := os.read_entire_file(path, context.allocator)
	if error != nil {return {}, fmt.aprintf("could not read publish configuration %q: %v", path, error)}
	defer delete(bytes)
	return decode_config(bytes)
}

decode_config :: proc(bytes: []u8) -> (Config, string) {
	if !config_json_syntax_valid(string(bytes)) {return {}, "publish.json must contain one strict JSON object (no comments, trailing commas, or trailing data)"}
	value, parse_error := json.parse(bytes, spec=.JSON, parse_integers=true)
	if parse_error != nil {return {}, fmt.aprintf("invalid publish.json: %v", parse_error)}
	object, is_object := value.(json.Object)
	if !is_object {return {}, "publish.json must contain an object"}
	if error := config_keys(object, {"$schema", "id", "name", "version", "executable", "targets", "content", "licenses", "build", "prune"}, "publish.json"); error != "" {return {}, error}
	if schema, found := object["$schema"]; found {
		if _, valid := schema.(json.String); !valid {return {}, "$schema must be a string"}
	}
	result: Config
	for key in ([]string{"id", "name", "version", "executable"}) {
		text, ok := object[key].(json.String)
		if !ok || strings.trim_space(text) == "" {return {}, fmt.aprintf("%s must be a non-empty string", key)}
		switch key {
		case "id": result.id = text
		case "name": result.name = text
		case "version": result.version = text
		case "executable": result.executable = text
		}
	}
	if !config_filename(result.id) {return {}, "id must be a portable filename component containing only ASCII letters, digits, '.', '_', and '-'"}
	if !config_filename(result.version, allow_plus=true) {return {}, "version must be a portable filename component containing only ASCII letters, digits, '.', '_', '-', and '+'"}
	if !config_filename(result.executable, allow_dot=false) {return {}, "executable must be an extensionless portable name containing only ASCII letters, digits, '_', and '-'"}
	if strings.to_lower(result.executable) == "licenses" {return {}, "executable cannot be named licenses: that directory is reserved for package notices"}
	for c in result.name {if c < 32 || c == 127 {return {}, "name cannot contain control characters"}}
	for key in ([]string{"targets", "content", "licenses"}) {
		raw, found := object[key]
		if !found && key == "licenses" {continue}
		array, ok := raw.(json.Array)
		if !ok || (key != "licenses" && len(array) == 0) {return {}, fmt.aprintf("%s must be a %sstring array", key, key == "licenses" ? "" : "non-empty ")}
		items := make([]string, len(array))
		seen := make(map[string]bool)
		for item, i in array {
			text, valid := item.(json.String)
			if !valid {return {}, fmt.aprintf("%s[%d] must be a string", key, i)}
			if key == "targets" {
				if text != "windows-amd64" && text != "linux-amd64" {return {}, fmt.aprintf("unsupported target %q; expected windows-amd64 or linux-amd64", text)}
			} else if !config_content_path(text) {return {}, fmt.aprintf("%s[%d] must be a portable project-relative path: %q", key, i, text)}
			if seen[text] {return {}, fmt.aprintf("%s contains duplicate entry %q", key, text)}
			seen[text] = true
			items[i] = text
		}
		switch key {
		case "targets": result.targets = items
		case "content": result.content = items
		case "licenses": result.licenses = items
		}
	}
	if raw, found := object["build"]; found {
		build, valid := raw.(json.Object)
		if !valid {return {}, "build must be an object"}
		if error := config_keys(build, {"collections", "defines", "extra_linker_flags"}, "build"); error != "" {return {}, error}
		if raw_collections, found := build["collections"]; found {
			collections, valid := raw_collections.(json.Object)
			if !valid {return {}, "build.collections must be an object mapping collection names to paths"}
			result.build.collections = make(map[string]string)
			for key, raw_path in collections {
				if !config_identifier(key) || key == "rune" || key == "r3d" {return {}, fmt.aprintf("invalid or reserved compiler collection name %q", key)}
				path, valid := raw_path.(json.String)
				if !valid || !config_collection_path(path) {return {}, fmt.aprintf("build.collections.%s must be a relative directory path", key)}
				result.build.collections[key] = path
			}
		}
		if raw_defines, found := build["defines"]; found {
			defines, valid := raw_defines.(json.Object)
			if !valid {return {}, "build.defines must be an object mapping identifiers to boolean, number, or string values"}
			result.build.defines = make(map[string]json.Value)
			for key, definition in defines {
				if !config_identifier(key) || key == "RUNE_PLAYER" || key == "RAYLIB_SHARED" {return {}, fmt.aprintf("invalid or reserved compiler define %q", key)}
				#partial switch v in definition {
				case json.Boolean, json.Integer, json.Float:
				case json.String:
					if strings.contains(string(v), "\x00") {return {}, fmt.aprintf("build.defines.%s cannot contain NUL; process arguments cannot preserve it", key)}
				case: return {}, fmt.aprintf("build.defines.%s must be a boolean, number, or string", key)
				}
				result.build.defines[key] = definition
			}
		}
		if raw_flags, found := build["extra_linker_flags"]; found {
			flags, valid := raw_flags.(json.String)
			if !valid {return {}, "build.extra_linker_flags must be a string"}
			for c in flags {if c == 0 || c == '\r' || c == '\n' {return {}, "build.extra_linker_flags cannot contain NUL or line breaks"}}
			result.build.extra_linker_flags = flags
		}
	}
	if raw, found := object["prune"]; found {
		prune, valid := raw.(json.Object)
		if !valid {return {}, "prune must be an object"}
		if error := config_keys(prune, {"enabled", "roots", "manifests"}, "prune"); error != "" {return {}, error}
		if raw_enabled, found := prune["enabled"]; found {
			enabled, valid := raw_enabled.(json.Boolean)
			if !valid {return {}, "prune.enabled must be a boolean"}
			result.prune.enabled = enabled
		}
		for field in ([2]string{"roots", "manifests"}) {
			if value, found := prune[field]; found {
				paths, error := config_path_array(value, fmt.aprintf("prune.%s", field))
				if error != "" {return {}, error}
				if field == "roots" {result.prune.roots = paths} else {result.prune.manifests = paths}
			}
		}
	}
	return result, ""
}

config_path_array :: proc(value: json.Value, location: string) -> ([]string, string) {
	array, valid := value.(json.Array)
	if !valid {return nil, fmt.aprintf("%s must be a string array", location)}
	paths := make([]string, len(array))
	seen := make(map[string]bool)
	for value, i in array {
		path, valid := value.(json.String)
		if !valid || !config_content_path(path) {return nil, fmt.aprintf("%s[%d] must be a portable project-relative path", location, i)}
		if seen[path] {return nil, fmt.aprintf("%s contains duplicate path %s", location, path)}
		seen[path] = true
		paths[i] = path
	}
	return paths, ""
}

config_keys :: proc(object: json.Object, allowed: []string, location: string) -> string {
	for key in object {
		found := false
		for candidate in allowed {if key == candidate {found = true; break}}
		if !found {return fmt.aprintf("unknown %s field %q", location, key)}
	}
	return ""
}

config_ascii_alnum :: proc(c: rune) -> bool {return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'}

config_identifier :: proc(text: string) -> bool {
	if len(text) == 0 {return false}
	for c, i in text {
		if c == '_' || 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' {continue}
		if i > 0 && '0' <= c && c <= '9' {continue}
		return false
	}
	return true
}

config_windows_device :: proc(text: string) -> bool {
	base := text
	if dot := strings.index_byte(base, '.'); dot >= 0 {base = base[:dot]}
	upper := strings.to_upper(base)
	defer delete(upper)
	if upper == "CON" || upper == "PRN" || upper == "AUX" || upper == "NUL" || upper == "CONIN$" || upper == "CONOUT$" {return true}
	if len(upper) == 4 && (upper[:3] == "COM" || upper[:3] == "LPT") && '1' <= upper[3] && upper[3] <= '9' {return true}
	if len(upper) == 5 && (upper[:3] == "COM" || upper[:3] == "LPT") && (upper[3:] == "¹" || upper[3:] == "²" || upper[3:] == "³") {return true}
	return false
}

config_filename :: proc(text: string, allow_dot := true, allow_plus := false) -> bool {
	if len(text) == 0 || !config_ascii_alnum(rune(text[0])) || text[len(text)-1] == '.' || config_windows_device(text) {return false}
	for c in text {if !config_ascii_alnum(c) && c != '_' && c != '-' && !(allow_dot && c == '.') && !(allow_plus && c == '+') {return false}}
	return true
}

config_content_path :: proc(path: string) -> bool {
	if len(path) == 0 || path[0] == '/' || path[0] == '\\' {return false}
	trimmed := path
	if trimmed[len(trimmed)-1] == '/' {trimmed = trimmed[:len(trimmed)-1]}
	if trimmed == "" {return false}
	for part in strings.split_iterator(&trimmed, "/") {
		if part == "" || part == "." || part == ".." || part[len(part)-1] == '.' || part[len(part)-1] == ' ' || config_windows_device(part) {return false}
		for c in part {
			if c < 32 || c == 127 || c == '\\' || c == ':' || c == '<' || c == '>' || c == '"' || c == '|' || c == '?' || c == '*' {return false}
		}
	}
	return true
}

config_collection_path :: proc(path: string) -> bool {
	if len(path) == 0 || path[0] == '/' || path[0] == '\\' {return false}
	for c in path {if c < 32 || c == 127 || c == ':' || c == '"' || c == '|' || c == '<' || c == '>' || c == '?' || c == '*' {return false}}
	return true
}

// The standard DOM parser diagnoses duplicate keys but accepts trailing commas
// and trailing input. Check the strict token grammar first, with bounded depth.
Config_JSON_Cursor :: struct {tokenizer: json.Tokenizer, token: json.Token, failed: bool}

config_json_next :: proc(cursor: ^Config_JSON_Cursor) {
	error: json.Error
	cursor.token, error = json.get_token(&cursor.tokenizer)
	cursor.failed = cursor.failed || (error != nil && error != .EOF)
}

config_json_value :: proc(cursor: ^Config_JSON_Cursor, depth: int) -> bool {
	if cursor.failed || depth > 64 {return false}
	#partial switch cursor.token.kind {
	case .Null, .True, .False, .Integer, .Float, .String:
		if cursor.token.kind == .String && !json.is_valid_string_literal(cursor.token.text, .JSON) {return false}
		if cursor.token.kind == .Integer {
			digits := cursor.token.text
			limit := "9223372036854775807"
			if digits[0] == '-' {digits = digits[1:]; limit = "9223372036854775808"}
			if len(digits) > len(limit) || (len(digits) == len(limit) && digits > limit) {return false}
		}
		if cursor.token.kind == .Float {
			number, valid := strconv.parse_f64(cursor.token.text)
			if !valid || math.is_inf(number) || math.is_nan(number) {return false}
		}
		config_json_next(cursor)
		return !cursor.failed
	case .Open_Brace, .Open_Bracket:
		object := cursor.token.kind == .Open_Brace
		closing: json.Token_Kind = object ? .Close_Brace : .Close_Bracket
		config_json_next(cursor)
		if cursor.token.kind == closing {config_json_next(cursor); return !cursor.failed}
		for {
			if object {
				if cursor.token.kind != .String || cursor.token.text == `""` || !json.is_valid_string_literal(cursor.token.text, .JSON) {return false}
				config_json_next(cursor)
				if cursor.token.kind != .Colon {return false}
				config_json_next(cursor)
			}
			if !config_json_value(cursor, depth+1) {return false}
			if cursor.token.kind == closing {config_json_next(cursor); return !cursor.failed}
			if cursor.token.kind != .Comma {return false}
			config_json_next(cursor)
			if cursor.token.kind == closing {return false}
		}
	}
	return false
}

config_json_syntax_valid :: proc(text: string) -> bool {
	for c in text {if c == 0 || c == '\v' || c == '\f' {return false}}
	cursor := Config_JSON_Cursor{tokenizer=json.make_tokenizer(text, .JSON, true)}
	config_json_next(&cursor)
	return config_json_value(&cursor, 0) && !cursor.failed && cursor.token.kind == .EOF
}
