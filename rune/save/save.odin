// Checkpoint persistence. The core package adds queued engine integration.
package save

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "rune:ecs"
import "rune:scene"

Format_Version :: 1

Entity_State :: struct {
	spawned: bool,
	name, tag, parent: string,
	layers: u64,
	enabled: bool,
	components: map[string]json.Value,
	// Custom adapters can include runtime data outside the scene component.
	state: map[string]json.Value,
}

Scene_State :: struct {
	baseline: []string,
	policies: []string,
	entities: map[string]Entity_State,
	removed: []string,
}

Document :: struct {
	format_version: int,
	game_id: string,
	game_version: int,
	active_scene: string,
	globals: json.Value,
	scenes: map[string]Scene_State,
}

// All storage in a checkpoint is owned by its arena, including migrations.
Checkpoint :: struct {
	document: Document,
	arena: ^mem.Dynamic_Arena,
}

Capture_Proc :: #type proc(world: ^ecs.World, entity: ecs.Entity, allocator: mem.Allocator) -> (json.Value, bool)
Restore_Proc :: #type proc(world: ^ecs.World, entity: ecs.Entity, value: json.Value) -> bool
Adapter :: struct {capture: Capture_Proc, restore: Restore_Proc}
// Runs before any world is loaded; update the document to the requested version.
Migrate_Proc :: #type proc(document: ^Document, from, to: int, allocator: mem.Allocator) -> bool
// Runs on the candidate after all entities/components exist. May validate stable
// references and create world-owned resources. Must not mutate external state.
Prepare_Proc :: #type proc(world: ^ecs.World, document: ^Document) -> bool
Options :: struct {
	game_id: string,
	game_version: int,
	// Empty uses the OS user-data directory / game_id / saves.
	directory: string,
	migrate: Migrate_Proc,
	prepare: Prepare_Proc,
}

Manager :: struct {
	options: Options,
	project_directory: string,
	policies: map[string]Adapter,
	checkpoint: Checkpoint,
	// Stable IDs explicitly opted into persistence for the current scene.
	spawned: map[string]bool,
	error: string,
	initialized: bool,
}

new_checkpoint :: proc() -> Checkpoint {
	arena, _ := mem.new(mem.Dynamic_Arena)
	mem.dynamic_arena_init(arena)
	return Checkpoint{arena = arena}
}
allocator :: proc(checkpoint: ^Checkpoint) -> mem.Allocator {return mem.dynamic_arena_allocator(checkpoint.arena)}
destroy_checkpoint :: proc(checkpoint: ^Checkpoint) {
	if checkpoint.arena != nil {mem.dynamic_arena_destroy(checkpoint.arena); mem.free(checkpoint.arena)}
	checkpoint^ = {}
}

fail :: proc(manager: ^Manager, format: string, args: ..any) -> bool {
	delete(manager.error)
	manager.error = fmt.aprintf(format, ..args)
	return false
}
last_error :: proc(manager: ^Manager) -> string {return manager.error}
clear_error :: proc(manager: ^Manager) {delete(manager.error); manager.error = ""}

valid_slot :: proc(slot: string) -> bool {
	if len(slot) == 0 || len(slot) > 80 {return false}
	for c in slot {if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {return false}}
	return true
}

init :: proc(project_directory: string, options: Options) -> (Manager, bool) {
	m: Manager
	if !valid_slot(options.game_id) || options.game_version < 1 {
		fail(&m, "Save game_id must be a slot-safe name and game_version must be positive")
		return m, false
	}
	m.checkpoint = new_checkpoint()
	a := allocator(&m.checkpoint)
	m.checkpoint.document = Document{format_version = Format_Version, game_version = options.game_version,
		game_id = strings.clone(options.game_id, a) or_else "", scenes = make(map[string]Scene_State, a)}
	m.options = options
	m.options.directory = ""
	m.options.game_id, _ = strings.clone(options.game_id)
	project_path, project_error := filepath.abs(project_directory)
	m.project_directory = project_path
	if project_error != nil {destroy(&m); fail(&m, "Could not resolve save project directory"); return m, false}
	directory := options.directory
	if directory == "" {
		base, err := os.user_data_dir(context.temp_allocator)
		if err != nil {destroy(&m); fail(&m, "Could not find the OS user-data directory"); return m, false}
		directory, _ = filepath.join({base, options.game_id, "saves"}, context.temp_allocator)
	}
	m.options.directory, project_error = filepath.abs(directory)
	if project_error != nil {destroy(&m); fail(&m, "Could not resolve save directory"); return m, false}
	m.policies = make(map[string]Adapter)
	m.spawned = make(map[string]bool)
	m.initialized = true
	return m, true
}

destroy :: proc(manager: ^Manager) {
	for name in manager.policies {delete(name)}
	delete(manager.policies)
	clear_spawns(manager)
	delete(manager.spawned)
	destroy_checkpoint(&manager.checkpoint)
	delete(manager.options.game_id)
	delete(manager.options.directory)
	delete(manager.project_directory)
	delete(manager.error)
	manager^ = {}
}

register_component :: proc(manager: ^Manager, registry: ^ecs.Component_Registry, $T: typeid, adapter := Adapter{}) -> bool {
	name, found := registry.names_by_type[typeid_of(T)]
	if !found {return fail(manager, "Save component must be registered with the ECS first")}
	return register_named(manager, registry, name, adapter)
}
register_named :: proc(manager: ^Manager, registry: ^ecs.Component_Registry, name: string, adapter := Adapter{}) -> bool {
	if !manager.initialized || !ecs.has_component(registry, name) {return fail(manager, "Unknown save component '%s'", name)}
	if (adapter.capture == nil) != (adapter.restore == nil) {return fail(manager, "Save adapters require both capture and restore")}
	descriptor := registry.components[name]
	if adapter.capture == nil && descriptor.type_id != nil && !automatic_type_safe(type_info_of(descriptor.type_id)) {
		return fail(manager, "Save component '%s' needs an adapter; use stable Entity_Ref values instead of handles or pointers", name)
	}
	if _, exists := manager.policies[name]; exists {return fail(manager, "Duplicate save policy '%s'", name)}
	owned, _ := strings.clone(name)
	manager.policies[owned] = adapter
	return true
}

clear_spawns :: proc(manager: ^Manager) {
	for id in manager.spawned {delete(id)}
	clear(&manager.spawned)
}
// Call after creating a runtime entity. Children must be tracked separately.
// The entity's complete JSON component configuration is its reconstruction
// template; registered adapters supply their own component representation.
track_spawn :: proc(manager: ^Manager, world: ^ecs.World, entity: ecs.Entity) -> bool {
	id, found := ecs.entity_id(world, entity)
	if !manager.initialized || !found || id == "" || !ecs.is_alive(world, entity) {return fail(manager, "Saved spawns require a live entity with a stable ID")}
	snapshot := manager.checkpoint.document.scenes[manager.checkpoint.document.active_scene]
	for base in snapshot.baseline {if base == id {return fail(manager, "'%s' is a scene entity, not a saved spawn", id)}}
	if !manager.spawned[id] {owned, _ := strings.clone(id); manager.spawned[owned] = true}
	return true
}

// Returns an owned canonical project-relative scene key in the supplied arena.
scene_key :: proc(manager: ^Manager, path: string, a: mem.Allocator) -> (string, bool) {
	resolved := path
	if !filepath.is_abs(path) {resolved, _ = filepath.join({manager.project_directory, path}, context.temp_allocator)}
	relative, err := filepath.rel(manager.project_directory, resolved, context.temp_allocator)
	if err != nil {return "", fail(manager, "Scene is outside the save project's directory")}
	key, _ := strings.replace_all(relative, "\\", "/", context.temp_allocator)
	if key == ".." || strings.has_prefix(key, "../") || key == "." {return "", fail(manager, "Scene is outside the save project's directory")}
	return strings.clone(key, a) or_else "", true
}

clone_checkpoint :: proc(source: ^Checkpoint) -> (Checkpoint, bool) {
	result := new_checkpoint()
	bytes, err := json.marshal(source.document, allocator = context.temp_allocator)
	if err != nil || json.unmarshal(bytes, &result.document, allocator = allocator(&result)) != nil {destroy_checkpoint(&result); return {}, false}
	return result, true
}

// Replaces session state only after a complete operation has succeeded.
commit :: proc(manager: ^Manager, checkpoint: ^Checkpoint) {
	destroy_checkpoint(&manager.checkpoint)
	manager.checkpoint = checkpoint^
	checkpoint^ = {}
	clear_spawns(manager)
	for id, state in manager.checkpoint.document.scenes[manager.checkpoint.document.active_scene].entities {
		if state.spawned {owned, _ := strings.clone(id); manager.spawned[owned] = true}
	}
}

set_globals :: proc(manager: ^Manager, value: json.Value) -> bool {
	if !manager.initialized {return false}
	// Clone the document to bound memory across repeated global edits.
	next, ok := clone_checkpoint(&manager.checkpoint)
	if !ok {return fail(manager, "Could not copy save globals")}
	next.document.globals = json.clone_value(value, allocator(&next))
	// Preserve spawns that have not yet been captured.
	destroy_checkpoint(&manager.checkpoint)
	manager.checkpoint = next
	return true
}
// Borrowed until the next save operation or set_globals. Clone to retain it.
globals :: proc(manager: ^Manager) -> json.Value {return manager.checkpoint.document.globals}

// Automatic persistence must never encode world-generation handles or native
// pointers. JSON-tagged exclusions are respected. Recursive pointer types must
// use an adapter, which also avoids recursion during registration.
automatic_type_safe :: proc(info: ^reflect.Type_Info, visited: map[typeid]bool = nil) -> bool {
	if info.id == typeid_of(ecs.Entity) {return false}
	visited := visited
	if visited == nil {visited = make(map[typeid]bool, context.temp_allocator)}
	if visited[info.id] {return true}
	visited[info.id] = true
	info := reflect.type_info_base(info)
	#partial switch value in info.variant {
	case reflect.Type_Info_Pointer, reflect.Type_Info_Multi_Pointer,
	     reflect.Type_Info_Procedure, reflect.Type_Info_Any, reflect.Type_Info_Type_Id:
		return false
	case reflect.Type_Info_Array:
		return automatic_type_safe(value.elem, visited)
	case reflect.Type_Info_Slice:
		return automatic_type_safe(value.elem, visited)
	case reflect.Type_Info_Dynamic_Array:
		return automatic_type_safe(value.elem, visited)
	case reflect.Type_Info_Map:
		return automatic_type_safe(value.key, visited) && automatic_type_safe(value.value, visited)
	case reflect.Type_Info_Struct:
		for field in reflect.struct_fields_zipped(info.id) {
			tag := reflect.struct_tag_get(field.tag, "json")
			if tag == "-" || strings.has_prefix(tag, "-,") {continue}
			if !automatic_type_safe(field.type, visited) {return false}
		}
	case reflect.Type_Info_Union:
		for variant in value.variants {if !automatic_type_safe(variant, visited) {return false}}
	}
	return true
}

// Establish the scene baseline before gameplay creates or destroys entities.
begin_scene :: proc(manager: ^Manager, world: ^ecs.World, path: string) -> bool {
	if !manager.initialized {return false}
	a := allocator(&manager.checkpoint)
	key, ok := scene_key(manager, path, a)
	if !ok {return false}
	state := Scene_State{entities = make(map[string]Entity_State, a)}
	ids := make([dynamic]string, a)
	for _, id in world.entity_ids {if id != "" {append(&ids, strings.clone(id, a) or_else "")}}
	state.baseline = ids[:]
	manager.checkpoint.document.scenes[key] = state
	manager.checkpoint.document.active_scene = key
	clear_spawns(manager)
	return true
}
