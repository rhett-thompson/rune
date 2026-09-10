package core

import "core:strings"
import "core:path/filepath"
import "rune:console"
import "rune:ecs"
import "rune:save"

Save_Action :: enum {None, Write, Load, Scene}
Save_Request :: struct {action: Save_Action, name: string, backup: bool}
Save_Result :: struct {
	// Incremented for every completed request, including failures.
	sequence: u64,
	action: Save_Action,
	ok: bool,
}

// Configure once, after init and before run. No directory is written until a
// save request succeeds. Explicit directories are useful for portable games.
configure_saves :: proc(engine: ^Engine, options: save.Options) -> bool {
	if engine == nil || engine.saves.initialized || engine.scene_loop_active {return false}
	m, ok := save.init(engine.project_directory, options)
	if !ok {save.fail(&engine.saves, "%s", save.last_error(&m)); save.destroy(&m); return false}
	save.destroy(&engine.saves)
	engine.saves = m
	if engine.has_active_world {
		absolute_path, _ := filepath.abs(engine.active_scene_path, context.temp_allocator)
		return save.begin_scene(&engine.saves, &engine.active_world, absolute_path)
	}
	return true
}
save_manager :: proc(engine: ^Engine) -> ^save.Manager {return &engine.saves}
last_save_error :: proc(engine: ^Engine) -> string {return save.last_error(&engine.saves)}
last_save_result :: proc(engine: ^Engine) -> Save_Result {return engine.save_result}

request_save :: proc(engine: ^Engine, slot: string) -> bool {return queue_save(engine, .Write, slot)}
request_load :: proc(engine: ^Engine, slot: string, backup := false) -> bool {return queue_save(engine, .Load, slot, backup)}
request_saved_scene :: proc(engine: ^Engine, path: string) -> bool {return queue_save(engine, .Scene, path)}
queue_save :: proc(engine: ^Engine, action: Save_Action, name: string, backup := false) -> bool {
	if engine == nil {return false}
	if !engine.saves.initialized || !engine.has_active_world {return save.fail(&engine.saves, "Save requests require configured saves and an engine-owned world")}
	if engine.save_request.action != .None || engine.save_processing {return save.fail(&engine.saves, "A save operation is already pending")}
	if action != .Scene && !save.valid_slot(name) {return save.fail(&engine.saves, "Invalid save slot name")}
	if name == "" {return save.fail(&engine.saves, "Empty save request")}
	engine.save_request = Save_Request{action = action, name = strings.clone(name) or_else "", backup = backup}
	return true
}

// The scene loop calls this at the next frame boundary, even while paused.
// Standalone/headless callers may invoke it between their own simulation steps.
process_save_requests :: proc(engine: ^Engine) {
	if engine.save_request.action == .None || engine.save_processing {return}
	request := engine.save_request
	engine.save_request = {}
	defer delete(request.name)
	engine.save_processing = true
	defer engine.save_processing = false
	save.clear_error(&engine.saves)
	ok := execute_save_request(engine, request)
	engine.save_result = Save_Result{sequence = engine.save_result.sequence + 1, action = request.action, ok = ok}
	if !ok && engine.is_running {console.error(&engine.console, last_save_error(engine))}
}

execute_save_request :: proc(engine: ^Engine, request: Save_Request) -> bool {
	if request.action == .Write || request.action == .Scene {
		for system in engine.systems {if system.before_save != nil {system.before_save(engine, &engine.active_world)}}
		if !save.capture(&engine.saves, &engine.active_world) {return false}
		if request.action == .Write {return save.write_slot(&engine.saves, request.name)}
	}
	candidate: save.Checkpoint
	loaded: bool
	if request.action == .Load {candidate, loaded = save.read_slot(&engine.saves, request.name, request.backup)}
	else {candidate, loaded = save.clone_checkpoint(&engine.saves.checkpoint)}
	if !loaded {return false}
	defer save.destroy_checkpoint(&candidate)
	path := candidate.document.active_scene if request.action == .Load else request.name
	key, key_ok := save.scene_key(&engine.saves, path, save.allocator(&candidate))
	if !key_ok {return false}
	_, visited := candidate.document.scenes[key]
	world, prepared := save.prepare_scene(&engine.saves, &candidate, key, &engine.registry, engine.project.layers)
	if !prepared {return false}
	if engine.scene_loop_active {run_shutdown_systems(engine, &engine.active_world)}
	ecs.destroy(&engine.active_world)
	engine.active_world = world
	engine.has_active_world = true
	save.commit(&engine.saves, &candidate)
	full_path, _ := filepath.join({engine.project_directory, key}, context.temp_allocator)
	engine.active_scene_path = watch_scene(engine, full_path)
	engine.fixed_accumulator = 0
	if engine.scene_loop_active {
		if request.action == .Load || visited {run_restore_systems(engine, &engine.active_world)}
		else {run_start_systems(engine, &engine.active_world)}
	}
	return true
}

run_restore_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	ecs.sync_terrains(world, &engine.assets)
	ecs.sync_navigation_3d(world, &engine.assets)
	for system in engine.systems {
		if system.on_save_restored != nil {system.on_save_restored(engine, world)}
	}
}
