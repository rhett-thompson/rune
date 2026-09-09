package assets

import "core:fmt"
import "core:strings"

Asset_Kind :: enum {
	Texture,
	Font,
	Material,
	Model,
	Animation,
	Tileset,
	Skybox,
	Terrain,
}

Asset_Operation :: enum {
	Load,
	Reload,
}

Diagnostic :: struct {
	kind:        Asset_Kind,
	operation:   Asset_Operation,
	source_path: string,
	field:       string,
	asset_path:  string,
	detail:      string,
}

Diagnostic_Log :: struct {
	pending:  [dynamic]Diagnostic,
	reported: map[string]bool,
}

init_diagnostic_log :: proc() -> Diagnostic_Log {
	return Diagnostic_Log{pending = make([dynamic]Diagnostic), reported = make(map[string]bool)}
}

record_failure :: proc(log: ^Diagnostic_Log, diagnostic: Diagnostic) -> bool {
	if log == nil {return false}
	key := diagnostic_key(diagnostic.source_path, diagnostic.field, diagnostic.asset_path)
	if log.reported[key] {
		delete(key)
		return false
	}
	log.reported[key] = true
	source_path, _ := strings.clone(diagnostic.source_path)
	field, _ := strings.clone(diagnostic.field)
	asset_path, _ := strings.clone(diagnostic.asset_path)
	detail, _ := strings.clone(diagnostic.detail)
	append(
		&log.pending,
		Diagnostic {
			kind = diagnostic.kind,
			operation = diagnostic.operation,
			source_path = source_path,
			field = field,
			asset_path = asset_path,
			detail = detail,
		},
	)
	return true
}

resolve_failure :: proc(log: ^Diagnostic_Log, source_path, field, asset_path: string) {
	// Animation updates check recovery every frame, usually with no failures.
	if log == nil || len(log.reported) == 0 {return}
	lookup := diagnostic_key(source_path, field, asset_path)
	owned_key := ""
	for key in log.reported {
		if key == lookup {
			owned_key = key
			break
		}
	}
	if len(owned_key) > 0 {
		delete_key(&log.reported, owned_key)
		delete(owned_key)
	}
	delete(lookup)
}

format_diagnostic :: proc(diagnostic: Diagnostic) -> string {
	kind := asset_kind_name(diagnostic.kind)
	operation := asset_operation_name(diagnostic.operation)
	if len(diagnostic.source_path) > 0 {
		return fmt.aprintf(
			"Asset %s failed [%s]: %s %s -> %s: %s",
			operation,
			kind,
			diagnostic.source_path,
			diagnostic.field,
			diagnostic.asset_path,
			diagnostic.detail,
		)
	}
	return fmt.aprintf(
		"Asset %s failed [%s]: %s -> %s: %s",
		operation,
		kind,
		diagnostic.field,
		diagnostic.asset_path,
		diagnostic.detail,
	)
}

report_failure :: proc(manager: ^Asset_Manager, diagnostic: Diagnostic) {
	if manager == nil || !record_failure(&manager.diagnostics, diagnostic) {return}
	message := format_diagnostic(diagnostic)
	defer delete(message)
	fmt.eprintln(message)
}

resolve_asset_failure :: proc(manager: ^Asset_Manager, source_path, field, asset_path: string) {
	if manager == nil {return}
	resolve_failure(&manager.diagnostics, source_path, field, asset_path)
}

resolve_asset_path_failures :: proc(manager: ^Asset_Manager, asset_path: string) {
	if manager == nil || len(manager.diagnostics.reported) == 0 {return}
	suffix := fmt.aprintf("\x1f%s", asset_path)
	defer delete(suffix)
	matching_keys := make([dynamic]string)
	defer delete(matching_keys)
	for key in manager.diagnostics.reported {
		if strings.has_suffix(key, suffix) {append(&matching_keys, key)}
	}
	for key in matching_keys {
		delete_key(&manager.diagnostics.reported, key)
		delete(key)
	}
}

pending_diagnostics :: proc(manager: ^Asset_Manager) -> []Diagnostic {
	if manager == nil {return nil}
	return manager.diagnostics.pending[:]
}

clear_pending_diagnostics :: proc(manager: ^Asset_Manager) {
	if manager == nil {return}
	clear_pending(&manager.diagnostics)
}

destroy_diagnostic_log :: proc(log: ^Diagnostic_Log) {
	if log == nil {return}
	clear_pending(log)
	for key in log.reported {
		delete(key)
	}
	delete(log.reported)
	delete(log.pending)
	log^ = {}
}

clear_pending :: proc(log: ^Diagnostic_Log) {
	for index in 0 ..< len(log.pending) {
		diagnostic := &log.pending[index]
		delete(diagnostic.source_path)
		delete(diagnostic.field)
		delete(diagnostic.asset_path)
		delete(diagnostic.detail)
	}
	clear(&log.pending)
}

diagnostic_key :: proc(source_path, field, asset_path: string) -> string {
	return fmt.aprintf("%s\x1f%s\x1f%s", source_path, field, asset_path)
}

asset_kind_name :: proc(kind: Asset_Kind) -> string {
	switch kind {
	case .Texture:
		return "texture"
	case .Font:
		return "font"
	case .Material:
		return "material"
	case .Model:
		return "model"
	case .Animation:
		return "animation"
	case .Terrain:
		return "terrain"
	case .Skybox:
		return "skybox"
	case .Tileset:
		return "tileset"
	}
	return "asset"
}

asset_operation_name :: proc(operation: Asset_Operation) -> string {
	switch operation {
	case .Load:
		return "load"
	case .Reload:
		return "reload"
	}
	return "operation"
}
