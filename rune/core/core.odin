package core

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "rune:assets"
import "rune:audio"
import "rune:console"
import "rune:ecs"
import "rune:gizmos"
import "rune:input"
import "rune:render"
import "rune:scene"
import "rune:save"
import "rune:validation"
import rl "vendor:raylib"

Window_Settings :: struct {
	width:      i32,
	height:     i32,
	title:      string,
	fullscreen: bool,
	// mode takes precedence over the legacy fullscreen flag.
	mode:       string,
	high_dpi:   bool,
	resizable:  bool,
	vsync:      bool,
	msaa_4x:    bool,
	show_fps:   bool,
}

Hot_Reload_Settings :: struct {
	navmeshes:        bool,
	enabled:          bool,
	poll_interval_ms: i32,
	scenes:           bool,
	prefabs:          bool,
	textures:         bool,
	models:           bool,
	terrains:         bool,
	materials:        bool,
	animations:       bool,
	tilesets:         bool,
}

default_hot_reload_settings :: proc() -> Hot_Reload_Settings {
	return Hot_Reload_Settings {
		navmeshes = true,
		enabled = true,
		poll_interval_ms = 250,
		scenes = true,
		prefabs = true,
		textures = true,
		models = true,
		terrains = true,
		materials = true,
		animations = true,
		tilesets = true,
	}
}

Project :: struct {
	render_2d:        render.Resolution_Settings,
	name:             string,
	startup_scene:    string,
	window:           Window_Settings,
	background_color: [4]u8,
	hot_reload:       Hot_Reload_Settings,
	gizmos:           gizmos.Settings,
	input:            string,
	// Layer names map to project-defined bit positions from 1 through 63.
	// Default is always engine-defined at bit 0 and does not need an entry.
	layers:           map[string]u8,
	raw_json:         json.Value,
	arena:            ^mem.Dynamic_Arena `json:"-"`,
}

System_Update_Proc :: #type proc(engine: ^Engine, world: ^ecs.World)
System_Draw_Proc :: #type proc(engine: ^Engine, world: ^ecs.World)
System_Reload_Proc :: #type proc(engine: ^Engine, world: ^ecs.World)

// System keeps game behavior in Odin while component data remains in JSON.
// Systems run in registration order within their update and draw phases.
System :: struct {
	name:              string,
	start:             System_Update_Proc,
	fixed_update:      System_Update_Proc,
	post_physics:      System_Update_Proc,
	update:            System_Update_Proc,
	// Runs every rendered frame, before simulation, including while paused.
	ui_update:         System_Update_Proc,
	pre_draw:          System_Draw_Proc,
	draw:              System_Draw_Proc,
	// Draw after the reference canvas is presented, at native UI resolution.
	draw_ui:           System_Draw_Proc,
	on_scene_reloaded: System_Reload_Proc,
	// Save-enabled games use this instead of start after restoring a world.
	on_save_restored:  System_Reload_Proc,
	// Capture game-owned global progress before a checkpoint or scene departure.
	before_save:       System_Update_Proc,
	shutdown:          System_Update_Proc,
}

Engine :: struct {
	saves:              save.Manager,
	save_request:       Save_Request,
	save_result:        Save_Result,
	save_processing:    bool,
	canvas:             render.Canvas,
	window:             Window_State,
	debug:              Debug_State,
	project:            Project,
	project_directory:  string,
	registry:           ecs.Component_Registry,
	assets:             assets.Asset_Manager,
	console:            console.Console,
	audio:              audio.Audio_System,
	gizmos:             gizmos.Settings,
	input:              input.Input,
	systems:            [dynamic]System,
	scene_watches:      map[string]map[string]i64,
	active_scene_path:  string,
	hot_reload_elapsed: f32,
	hot_reload_due:     bool,
	delta_time:         f32,
	frame_delta_time:   f32,
	game_paused:        bool,
	fixed_delta_time:   f32,
	fixed_accumulator:  f32,
	active_world:       ecs.World,
	has_active_world:   bool,
	scene_loop_active:  bool,
	is_running:         bool,
	exit_requested:     bool,
	fps_sample_started: f64,
	fps_sample_frames:  u64,
}

Update_Proc :: #type proc(engine: ^Engine)
Draw_Proc :: #type proc(engine: ^Engine)

// Native window dragging can pause the game loop for seconds. Simulation uses
// a capped delta so a resumed frame cannot throw moving entities through the
// world or off screen.
Max_Simulation_Delta: f32 : 0.1

load_project :: proc(path: string) -> (Project, bool) {
	validation_report := validation.validate_project(path)
	defer validation.destroy_report(&validation_report)
	if !validation.is_valid(&validation_report) {return {}, false}
	arena, _ := mem.new(mem.Dynamic_Arena)
	assert(arena != nil)
	mem.dynamic_arena_init(arena)
	allocator := mem.dynamic_arena_allocator(arena)
	project := Project {
		window = Window_Settings{show_fps = true, high_dpi = true},
		hot_reload = default_hot_reload_settings(),
		gizmos     = gizmos.default_settings(),
		arena      = arena,
	}
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {
		destroy_project(&project)
		return {}, false
	}

	if json.unmarshal(data, &project, allocator = allocator) != nil {
		destroy_project(&project)
		return {}, false
	}
	if json.unmarshal(data, &project.raw_json, allocator = allocator) != nil {
		destroy_project(&project)
		return {}, false
	}
	if !render.resolution_valid(project.render_2d) {destroy_project(&project); return {},false}
	for layer_name, layer_index in project.layers {
		if layer_name == "Default" || layer_index == ecs.Default_Layer || layer_index >= 64 {
			destroy_project(&project)
			return {}, false
		}
	}
	if project.hot_reload.poll_interval_ms <= 0 {
		project.hot_reload.poll_interval_ms = 250
	}

	return project, true
}

// destroy_project releases the typed settings and preserved raw JSON returned
// by load_project. Engine shutdown handles this for engine-owned projects.
destroy_project :: proc(project: ^Project) {
	if project == nil || project.arena == nil {return}
	mem.dynamic_arena_destroy(project.arena)
	mem.free(project.arena)
	project^ = {}
}

project_allocator :: proc(project: ^Project) -> mem.Allocator {
	return mem.dynamic_arena_allocator(project.arena)
}

init :: proc(project_path: string) -> (Engine, bool) {
	project, ok := load_project(project_path)
	if !ok {
		return {}, false
	}

	if project.window.width <= 0 {
		project.window.width = 1280
	}
	if project.window.height <= 0 {
		project.window.height = 720
	}
	if len(project.window.title) == 0 {
		project.window.title = project.name
	}
	// JSON projects that omit background_color decode to transparent black. Use
	// the previous white clear color until a project explicitly supplies alpha.
	if project.background_color[3] == 0 {
		project.background_color = {255, 255, 255, 255}
	}

	registry := ecs.init_registry()
	if !ecs.register_builtin_components(&registry) {
		ecs.destroy_registry(&registry)
		destroy_project(&project)
		return {}, false
	}
	project_directory_view, _ := filepath.split(project_path)
	project_directory, _ := strings.clone(project_directory_view, project_allocator(&project))
	input_path := project.input
	if len(input_path) > 0 {
		input_path, _ = filepath.join({project_directory, input_path}, project_allocator(&project))
	}
	input_data, input_ok := input.load(input_path)
	if !input_ok {
		ecs.destroy_registry(&registry)
		destroy_project(&project)
		return {}, false
	}

	title, _ := strings.clone_to_cstring(project.window.title)
	defer delete(title)
	flags: rl.ConfigFlags
	if project.window.msaa_4x {flags += {.MSAA_4X_HINT}}
	if project.window.high_dpi {flags += {.WINDOW_HIGHDPI}}
	if project.window.resizable {flags += {.WINDOW_RESIZABLE}}
	rl.SetConfigFlags(flags)
	rl.InitWindow(project.window.width, project.window.height, title)
	fit_window_to_monitor()
	if project.window.vsync {
		rl.SetTargetFPS(60)
	}

	asset_manager := assets.init(project_directory)
	audio_system := audio.init(project_directory)
	dev_console := console.init()
	register_debug_commands(&dev_console)
	for argument in os.args[1:] {
		prefix :: "--console-dir="
		if strings.has_prefix(argument, prefix) {
			if !console.enable_remote(&dev_console, argument[len(prefix):]) {
				console.error(&dev_console, "Could not enable local console inbox.")
			}
		}
	}
	engine := Engine {
			project = project,
			project_directory = project_directory,
			registry = registry,
			assets = asset_manager,
			audio = audio_system,
			gizmos = project.gizmos,
			console = dev_console,
			input = input_data,
			systems = make([dynamic]System),
			scene_watches = make(map[string]map[string]i64),
			fixed_delta_time = ecs.Physics2D_Fixed_Delta,
			is_running = true,
			fps_sample_started = rl.GetTime(),
		}
	mode := Window_Mode.Fullscreen if project.window.fullscreen else Window_Mode.Windowed
	if project.window.mode != "" {mode, _ = parse_window_mode(project.window.mode)}
	set_window_mode(&engine, mode)
	return engine, true
}

// input_state exposes project-defined input actions and axes to game systems.
input_state :: proc(engine: ^Engine) -> ^input.Input {return &engine.input}

// project_json exposes the full root project.json document, including
// game-defined fields that are not part of Rune's typed Project settings.
project_json :: proc(engine: ^Engine) -> json.Value {return engine.project.raw_json}

// project_value returns a top-level project.json value by key. Use this for
// game-owned global settings while keeping Rune's required settings typed.
project_value :: proc(engine: ^Engine, key: string) -> (json.Value, bool) {
	object, ok := engine.project.raw_json.(json.Object)
	if !ok {return {}, false}
	value, found := object[key]
	return value, found
}

// developer_console exposes the engine-owned runtime console. Register
// project-specific commands and write diagnostic messages through this value.
developer_console :: proc(engine: ^Engine) -> ^console.Console {
	engine.console.user_data = engine
	return &engine.console
}

// component_registry exposes the engine-initialized registry. Built-in
// components are ready after init; games only register their own components.
component_registry :: proc(engine: ^Engine) -> ^ecs.Component_Registry {
	return &engine.registry
}

// asset_manager exposes project-relative asset loading and texture caching to
// render systems. Asset paths in scene JSON resolve from the project directory.
asset_manager :: proc(engine: ^Engine) -> ^assets.Asset_Manager {
	return &engine.assets
}

// gizmo_settings exposes runtime debug visualization flags. F3 toggles the
// overlay while a game is running; projects may also configure the default
// category flags in project.json.
gizmo_settings :: proc(engine: ^Engine) -> ^gizmos.Settings {
	return &engine.gizmos
}

// draw_gizmos renders the runtime debug overlay for callback-based programs.
// The engine-owned rune.run workflow draws it automatically after registered
// draw systems.
draw_gizmos :: proc(engine: ^Engine, world: ^ecs.World) {
	gizmos.draw_scene(world, engine.gizmos)
}

// AudioPlayer is repeatable, so playback commands address an entity and its
// stable component instance name.
// The engine owns the audio device and per-entity raylib sound instances.
play_audio :: proc(
	engine: ^Engine,
	world: ^ecs.World,
	entity: ecs.Entity,
	instance_name: string,
) -> bool {
	return audio.play(&engine.audio, world, entity, instance_name)
}

stop_audio :: proc(engine: ^Engine, entity: ecs.Entity, instance_name: string) -> bool {
	return audio.stop(&engine.audio, entity, instance_name)
}

audio_is_playing :: proc(engine: ^Engine, entity: ecs.Entity, instance_name: string) -> bool {
	return audio.is_playing(&engine.audio, entity, instance_name)
}

// register_system appends a game system to the deterministic lifecycle order.
// Names must be unique so accidental duplicate registration is rejected.
register_system :: proc(engine: ^Engine, system: System) -> bool {
	if len(system.name) == 0 {return false}
	for registered in engine.systems {
		if registered.name == system.name {return false}
	}
	append(&engine.systems, system)
	return true
}

// layer_names returns the project-defined layer-to-bit mapping for scene
// loading and systems that need to build a filter mask.
layer_names :: proc(engine: ^Engine) -> map[string]u8 {
	return engine.project.layers
}

// load_scene is the normal runtime entry point. It supplies the project's
// optional layer names while scene.load remains useful for standalone tools.
load_scene :: proc(engine: ^Engine, path: string) -> (ecs.World, bool) {
	world, loaded := scene.load_with_layers(path, &engine.registry, engine.project.layers)
	if loaded {
		engine.active_scene_path = watch_scene(engine, path)
	}
	return world, loaded
}

// load_active_scene gives the Engine clear ownership of the ordinary runtime
// World. Tools and advanced code can continue using load_scene directly.
load_active_scene :: proc(engine: ^Engine, path: string) -> bool {
	resolved_path := path
	joined_path: string
	defer if len(joined_path) > 0 {delete(joined_path)}
	if !filepath.is_abs(resolved_path) {
		joined_path, _ = filepath.join({engine.project_directory, resolved_path})
		resolved_path = joined_path
	}
	world, loaded := load_scene(engine, resolved_path)
	if !loaded {return false}
	if engine.has_active_world {ecs.destroy(&engine.active_world)}
	engine.active_world = world
	engine.has_active_world = true
	if engine.saves.initialized {
		absolute_path, _ := filepath.abs(resolved_path, context.temp_allocator)
		return save.begin_scene(&engine.saves, &engine.active_world, absolute_path)
	}
	return true
}

// change_scene replaces the engine-owned World while preserving the registered
// system lifecycle. The old scene remains active when the new scene cannot be
// loaded. Calls made by an update system take effect immediately, before the
// remaining systems and draw phase run.
// With saves configured, the change is queued for the next frame boundary and
// carries per-scene progress; inspect last_save_result for completion.
change_scene :: proc(engine: ^Engine, path: string) -> bool {
	if engine == nil || !engine.has_active_world || len(path) == 0 {return false}
	if engine.saves.initialized {return request_saved_scene(engine, path)}
	resolved_path := path
	joined_path: string
	defer if len(joined_path) > 0 {delete(joined_path)}
	if !filepath.is_abs(resolved_path) {
		joined_path, _ = filepath.join({engine.project_directory, resolved_path})
		resolved_path = joined_path
	}
	next_world, loaded := scene.load_with_layers(
		resolved_path,
		&engine.registry,
		engine.project.layers,
	)
	if !loaded {return false}
	if engine.scene_loop_active {run_shutdown_systems(engine, &engine.active_world)}
	ecs.destroy(&engine.active_world)
	engine.active_world = next_world
	engine.has_active_world = true
	engine.active_scene_path = watch_scene(engine, resolved_path)
	if engine.scene_loop_active {run_start_systems(engine, &engine.active_world)}
	return true
}

active_world :: proc(engine: ^Engine) -> (^ecs.World, bool) {
	if engine == nil || !engine.has_active_world {return nil, false}
	return &engine.active_world, true
}

last_scene_error :: proc() -> string {return scene.last_load_error()}

// reload_scene_if_changed updates a loaded World when its scene or any nested
// referenced prefab changes. Component-value-only scene saves are applied onto
// the existing World and return false so cached Entity handles stay valid and
// reload callbacks do not run. Structural changes still rebuild the World and
// return true; game code must reacquire cached entity IDs after that.
reload_scene_if_changed :: proc(engine: ^Engine, world: ^ecs.World, path: string) -> bool {
	if !engine.project.hot_reload.enabled ||
	   !engine.project.hot_reload.scenes ||
	   !engine.hot_reload_due ||
	   !scene_changed(engine, path) {return false}
	reloaded, loaded := scene.load_with_layers(path, &engine.registry, engine.project.layers)
	if !loaded {return false}
	if ecs.apply_value_snapshot(world, &reloaded) {
		ecs.destroy(&reloaded)
		engine.active_scene_path = watch_scene(engine, path)
		return false
	}
	ecs.destroy(world)
	world^ = reloaded
	engine.active_scene_path = watch_scene(engine, path)
	return true
}

watch_scene :: proc(engine: ^Engine, path: string) -> string {
	owned_scene_path := ""
	for watched_path in engine.scene_watches {
		if watched_path == path {
			owned_scene_path = watched_path
			break
		}
	}
	if len(owned_scene_path) == 0 {
		owned_scene_path, _ = strings.clone(path)
	}
	if previous, watched := engine.scene_watches[owned_scene_path]; watched {
		destroy_scene_watch(previous)
		delete_key(&engine.scene_watches, owned_scene_path)
	}
	paths, found := scene.dependency_paths(path)
	if !found {
		engine.scene_watches[owned_scene_path] = make(map[string]i64)
		return owned_scene_path
	}
	defer scene.destroy_dependency_paths(paths)
	watch := make(map[string]i64)
	for dependency_path in paths {
		if dependency_path != path && !engine.project.hot_reload.prefabs {continue}
		if _, exists := watch[dependency_path]; exists {continue}
		owned_dependency, _ := strings.clone(dependency_path)
		watch[owned_dependency] = file_modified_time(dependency_path)
	}
	engine.scene_watches[owned_scene_path] = watch
	return owned_scene_path
}

destroy_scene_watch :: proc(watch: map[string]i64) {
	paths := make([dynamic]string)
	defer delete(paths)
	for path in watch {append(&paths, path)}
	delete(watch)
	for path in paths {delete(path)}
}

scene_changed :: proc(engine: ^Engine, path: string) -> bool {
	watch, found := engine.scene_watches[path]
	if !found {
		watch_scene(engine, path)
		return false
	}
	for dependency_path, recorded_time in watch {
		if file_modified_time(dependency_path) != recorded_time {return true}
	}
	return false
}

file_modified_time :: proc(path: string) -> i64 {
	modified, err := os.modification_time_by_path(path)
	if err != nil {return -1}
	return time.to_unix_nanoseconds(modified)
}

// run follows a familiar game-object lifecycle: on_update changes game state,
// then on_draw presents that state. Rendering is deliberately outside update so
// component systems never have to mix simulation with raylib draw calls.
run_callbacks :: proc(engine: ^Engine, on_update: Update_Proc, on_draw: Draw_Proc) {
	defer shutdown(engine)
	bind_debug_console(engine, nil)
	frame_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&frame_arena)
	defer mem.dynamic_arena_destroy(&frame_arena)

	for !engine.exit_requested && !rl.WindowShouldClose() {
		context.temp_allocator = mem.dynamic_arena_allocator(&frame_arena)
		defer {
			engine.console.result_data = {}
			engine.console.frame_metadata = {}
			mem.dynamic_arena_reset(&frame_arena)
		}
		begin_frame(engine)
		if debug_simulation_tick(engine) {
			started := rl.GetTime()
			on_update(engine)
			engine.debug.sample.update_ms = (rl.GetTime() - started) * 1000
			if engine.debug.steps_remaining > 0 {engine.debug.fixed_steps += 1}
			debug_simulation_finished(engine)
		}

		draw_started := rl.GetTime()
		rl.BeginDrawing()
		if !render.begin_canvas(&engine.canvas,engine.project.render_2d) {request_exit(engine)}
		clear_background(engine)
		on_draw(engine)
		render.end_canvas(&engine.canvas)
		flush_asset_diagnostics(engine)
		engine.console.frame_metadata = debug_frame_metadata(engine)
		console.finish_frame(&engine.console)
		console.draw(&engine.console)
		engine.debug.sample.render_ms = (rl.GetTime() - draw_started) * 1000
		rl.EndDrawing()
		update_fps_title(engine)
		debug_profile_finished_frame(engine)
	}
}

run_project :: proc(engine: ^Engine) -> bool {
	if engine == nil || !engine.is_running {return false}
	defer shutdown(engine)
	if !engine.has_active_world {
		if len(engine.project.startup_scene) == 0 ||
		   !load_active_scene(engine, engine.project.startup_scene) {
			return false
		}
	}
	run_scene_loop(engine, &engine.active_world)
	return true
}

// run supports the simple engine-owned startup-scene workflow as well as the
// original callback loop used by low-level raylib examples.
run :: proc {
	run_project,
	run_callbacks,
}

// run_scene drives registered systems against a loaded World. It preserves the
// callback-based run API for small programs while providing the normal ECS
// lifecycle for games. Scene reload notifications happen before update systems.
run_scene :: proc(engine: ^Engine, world: ^ecs.World) {
	defer ecs.destroy(world)
	defer shutdown(engine)
	run_scene_loop(engine, world)
}

run_scene_loop :: proc(engine: ^Engine, world: ^ecs.World) {
	bind_debug_console(engine, world)
	engine.scene_loop_active = true
	run_start_systems(engine, world)
	defer {
		run_shutdown_systems(engine, world)
		engine.scene_loop_active = false
		engine.debug.world = nil
	}
	frame_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&frame_arena)
	defer mem.dynamic_arena_destroy(&frame_arena)
	for !engine.exit_requested && !rl.WindowShouldClose() {
		// Scratch results belong to this frame; keep blocks for reuse without
		// resetting temporary allocations owned by the caller of run_scene.
		context.temp_allocator = mem.dynamic_arena_allocator(&frame_arena)
		defer {
			engine.console.result_data = {}
			engine.console.frame_metadata = {}
			mem.dynamic_arena_reset(&frame_arena)
		}
		begin_frame(engine)
		if world == &engine.active_world {process_save_requests(engine)}
		if len(engine.active_scene_path) > 0 &&
		   reload_scene_if_changed(engine, world, engine.active_scene_path) {
			run_scene_reload_systems(engine, world)
		}
		ecs.sync_terrains(world, &engine.assets)
		ecs.sync_navigation_3d(world, &engine.assets)
		render.update_tilesets(world, &engine.assets)
		for system in engine.systems {
			if system.ui_update != nil {system.ui_update(engine, world)}
		}
		if debug_simulation_tick(engine) {
			fixed_started := rl.GetTime()
			run_fixed_pipeline(engine, world)
			engine.debug.sample.fixed_update_ms = (rl.GetTime() - fixed_started) * 1000
			update_started := rl.GetTime()
			update_orbit_cameras_3d(engine, world)
			run_update_systems(engine, world)
			ecs.update_camera_follows_2d(
				world,
				engine.delta_time,
				canvas_size(engine),
			)
			render.update_sprite_animators(world, &engine.assets, engine.delta_time)
			ecs.update_particles_2d(world, engine.delta_time)
			ecs.update_lifetimes(world, engine.delta_time)
			engine.debug.sample.update_ms = (rl.GetTime() - update_started) * 1000
			debug_simulation_finished(engine)
		}
		audio.update(&engine.audio, world, engine.frame_delta_time)

		draw_started := rl.GetTime()
		rl.BeginDrawing()
		if !render.begin_canvas(&engine.canvas,engine.project.render_2d) {request_exit(engine)}
		clear_background(engine)
		run_pre_draw_systems(engine, world)
		render.draw_scene_2d(world, &engine.assets)
		run_draw_systems(engine, world)
		gizmos.draw_scene(world, engine.gizmos)
		render.end_canvas(&engine.canvas)
		for system in engine.systems {if system.draw_ui != nil {system.draw_ui(engine,world)}}
		flush_asset_diagnostics(engine)
		engine.console.frame_metadata = debug_frame_metadata(engine)
		console.finish_frame(&engine.console)
		console.draw(&engine.console)
		engine.debug.sample.render_ms = (rl.GetTime() - draw_started) * 1000
		rl.EndDrawing()
		update_fps_title(engine)
		debug_profile_finished_frame(engine)
	}
}

// Measure completed frames against wall time, including presentation/frame
// limiting. Simulation delta is capped and would overstate FPS after stalls.
update_fps_title :: proc(engine: ^Engine) {
	engine.fps_sample_frames += 1
	now := rl.GetTime()
	elapsed := now - engine.fps_sample_started
	if elapsed < 1 {return}
	fps := u64(f64(engine.fps_sample_frames) / elapsed + 0.5)
	engine.debug.fps = f64(engine.fps_sample_frames) / elapsed
	if engine.project.window.show_fps {
		rl.SetWindowTitle(fmt.ctprintf("%s | %d FPS", engine.project.window.title, fps))
	}
	engine.fps_sample_started = now
	engine.fps_sample_frames = 0
}

// request_exit stops the active loop after the current frame. GPU-backed
// systems are then shut down before the engine closes the raylib window.
request_exit :: proc(engine: ^Engine) {
	if engine != nil {engine.exit_requested = true}
}

// Game pause is independent of the developer console's pause/step controls.
// UI updates, rendering, file polling, and audio servicing continue.
set_paused :: proc(engine: ^Engine, paused: bool) {
	if engine == nil || engine.game_paused == paused {return}
	engine.game_paused = paused
	engine.fixed_accumulator = 0
}

is_paused :: proc(engine: ^Engine) -> bool {
	return engine != nil && (engine.game_paused || engine.debug.paused)
}

run_start_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	ecs.sync_terrains(world,&engine.assets)
	ecs.sync_navigation_3d(world,&engine.assets)
	for system in engine.systems {
		if system.start != nil {system.start(engine, world)}
	}
}

run_fixed_pipeline :: proc(engine: ^Engine, world: ^ecs.World) {
	engine.fixed_accumulator += engine.delta_time
	steps := 0
	for engine.fixed_accumulator >= engine.fixed_delta_time && steps < 8 {
		for system in engine.systems {
			if system.fixed_update != nil {system.fixed_update(engine, world)}
		}
		ecs.update_navigation_3d(world, engine.fixed_delta_time)
		ecs.physics_2d_update(world, engine.fixed_delta_time)
		ecs.physics_3d_update(world, engine.fixed_delta_time)
		ecs.update_triggers_3d(world)
		for system in engine.systems {
			if system.post_physics != nil {system.post_physics(engine, world)}
		}
		engine.debug.fixed_steps += 1
		engine.fixed_accumulator -= engine.fixed_delta_time
		steps += 1
	}
	if steps == 8 {engine.fixed_accumulator = 0}
}

run_shutdown_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	for index := len(engine.systems) - 1; index >= 0; index -= 1 {
		system := engine.systems[index]
		if system.shutdown != nil {system.shutdown(engine, world)}
	}
}

run_update_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	for system in engine.systems {
		if system.update != nil {system.update(engine, world)}
	}
}

run_draw_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	for system in engine.systems {
		if system.draw != nil {system.draw(engine, world)}
	}
}

run_pre_draw_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	for system in engine.systems {
		if system.pre_draw != nil {system.pre_draw(engine, world)}
	}
}

run_scene_reload_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	ecs.sync_terrains(world,&engine.assets)
	ecs.sync_navigation_3d(world,&engine.assets)
	for system in engine.systems {
		if system.on_scene_reloaded != nil {system.on_scene_reloaded(engine, world)}
	}
}

update_orbit_cameras_3d :: proc(engine: ^Engine, world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "OrbitCamera3D") {
		orbit, has_orbit := ecs.get_orbit_camera_3d(world, entity)
		camera, has_camera := ecs.get_camera_3d(world, entity)
		if !has_orbit || !has_camera {continue}
		transform := ecs.update_orbit_camera_3d(&orbit, &engine.input, engine.delta_time)
		camera.target = orbit.target
		ecs.set_orbit_camera_3d(world, entity, orbit)
		ecs.set_transform(world, entity, transform)
		ecs.set_camera_3d(world, entity, camera)
	}
}

begin_frame :: proc(engine: ^Engine) {
	engine.debug.frame += 1
	engine.debug.frame_started = rl.GetTime()
	engine.debug.sample = {}
	engine.delta_time = rl.GetFrameTime()
	if engine.delta_time > Max_Simulation_Delta {
		engine.delta_time = Max_Simulation_Delta
	}
	engine.frame_delta_time = engine.delta_time
	engine.hot_reload_due = hot_reload_poll_due(engine)
	if engine.hot_reload_due &&
	   engine.project.hot_reload.enabled &&
	   engine.project.hot_reload.textures {
		assets.refresh(&engine.assets)
	}
	if engine.hot_reload_due &&
	   engine.project.hot_reload.enabled &&
	   engine.project.hot_reload.models {
		assets.refresh_models(&engine.assets)
		assets.refresh_skyboxes(&engine.assets)
	}
	if engine.hot_reload_due && engine.project.hot_reload.enabled && engine.project.hot_reload.terrains {
		assets.refresh_terrains(&engine.assets)
	}
	if engine.hot_reload_due && engine.project.hot_reload.enabled && engine.project.hot_reload.navmeshes {
		assets.refresh_navmeshes(&engine.assets)
	}
	if engine.hot_reload_due &&
	   engine.project.hot_reload.enabled &&
	   engine.project.hot_reload.materials {
		assets.refresh_materials(&engine.assets)
	}
	if engine.hot_reload_due &&
	   engine.project.hot_reload.enabled &&
	   engine.project.hot_reload.animations {
		assets.refresh_animations(&engine.assets)
	}
	if engine.hot_reload_due &&
	   engine.project.hot_reload.enabled &&
	   engine.project.hot_reload.tilesets {
		assets.refresh_tilesets(&engine.assets)
	}
	flush_asset_diagnostics(engine)
	if rl.IsKeyPressed(.F3) {
		engine.gizmos.enabled = !engine.gizmos.enabled
		if engine.gizmos.enabled {
			console.info(&engine.console, "Gizmos enabled")
		} else {
			console.info(&engine.console, "Gizmos disabled")
		}
	}
	input.update(&engine.input)
	console.update(&engine.console)
}

flush_asset_diagnostics :: proc(engine: ^Engine) {
	if engine == nil {return}
	for diagnostic in assets.pending_diagnostics(&engine.assets) {
		message := assets.format_diagnostic(diagnostic)
		console.error(&engine.console, message)
		delete(message)
	}
	assets.clear_pending_diagnostics(&engine.assets)
}

clear_background :: proc(engine: ^Engine) {
	rl.ClearBackground(
		rl.Color {
			engine.project.background_color[0],
			engine.project.background_color[1],
			engine.project.background_color[2],
			engine.project.background_color[3],
		},
	)
}

hot_reload_poll_due :: proc(engine: ^Engine) -> bool {
	if !engine.project.hot_reload.enabled {return false}
	engine.hot_reload_elapsed += engine.delta_time
	interval := f32(engine.project.hot_reload.poll_interval_ms) / 1000
	if engine.hot_reload_elapsed < interval {return false}
	engine.hot_reload_elapsed = 0
	return true
}

shutdown :: proc(engine: ^Engine) {
	if engine.is_running {
		delete(engine.save_request.name)
		engine.save_request = {}
		save.destroy(&engine.saves)
		if engine.console.defer_reply {
			engine.console.defer_reply = false
			engine.console.result_data = {}
			console.error(&engine.console, "Engine stopped before the command completed.")
			console.finish_remote(&engine.console)
		}
		if engine.has_active_world {
			ecs.destroy(&engine.active_world)
			engine.has_active_world = false
		}
		audio.shutdown(&engine.audio)
		render.destroy_canvas(&engine.canvas)
		assets.shutdown(&engine.assets)
		ecs.destroy_registry(&engine.registry)
		scene_paths := make([dynamic]string)
		for path, watch in engine.scene_watches {
			append(&scene_paths, path)
			destroy_scene_watch(watch)
		}
		delete(engine.scene_watches)
		for path in scene_paths {delete(path)}
		delete(scene_paths)
		delete(engine.systems)
		input.destroy(&engine.input)
		destroy_project(&engine.project)
		rl.CloseWindow()
		engine.is_running = false
	}
}
