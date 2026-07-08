package core

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "rune:audio"
import "rune:assets"
import "rune:console"
import "rune:ecs"
import "rune:gizmos"
import "rune:input"
import "rune:scene"
import "rune:validation"
import rl "vendor:raylib"

Window_Settings :: struct {
	width:      i32,
	height:     i32,
	title:      string,
	fullscreen: bool,
	vsync:      bool,
	msaa_4x:    bool,
}

Hot_Reload_Settings :: struct {
	enabled:          bool,
	poll_interval_ms: i32,
	scenes:           bool,
	prefabs:          bool,
	textures:         bool,
	models:           bool,
	materials:        bool,
}

default_hot_reload_settings :: proc() -> Hot_Reload_Settings {
	return Hot_Reload_Settings{enabled = true, poll_interval_ms = 250, scenes = true, prefabs = true, textures = true, models = true, materials = true}
}

Project :: struct {
	name:             string,
	startup_scene:    string,
	window:           Window_Settings,
	background_color: [4]u8,
	hot_reload:       Hot_Reload_Settings,
	gizmos:           gizmos.Settings,
	input:            string,
	// Layer names map to project-defined bit positions from 1 through 63.
	// Default is always engine-defined at bit 0 and does not need an entry.
	layers:        map[string]u8,
	raw_json:      json.Value,
}

System_Update_Proc :: #type proc(engine: ^Engine, world: ^ecs.World)
System_Draw_Proc   :: #type proc(engine: ^Engine, world: ^ecs.World)
System_Reload_Proc :: #type proc(engine: ^Engine, world: ^ecs.World)

// System keeps game behavior in Odin while component data remains in JSON.
// Systems run in registration order within their update and draw phases.
System :: struct {
	name:              string,
	update:            System_Update_Proc,
	draw:              System_Draw_Proc,
	on_scene_reloaded: System_Reload_Proc,
}

Engine :: struct {
	project:    Project,
	registry:   ecs.Component_Registry,
	assets:     assets.Asset_Manager,
	console:    console.Console,
	audio:      audio.Audio_System,
	gizmos:     gizmos.Settings,
	input:      input.Input,
	systems:    [dynamic]System,
	scene_watches: map[string]map[string]i64,
	active_scene_path: string,
	hot_reload_elapsed: f32,
	hot_reload_due: bool,
	delta_time: f32,
	is_running: bool,
}

Update_Proc :: #type proc(engine: ^Engine)
Draw_Proc   :: #type proc(engine: ^Engine)

// Native window dragging can pause the game loop for seconds. Simulation uses
// a capped delta so a resumed frame cannot throw moving entities through the
// world or off screen.
Max_Simulation_Delta : f32 : 0.1

load_project :: proc(path: string) -> (Project, bool) {
	validation_report := validation.validate_project(path)
	if !validation.is_valid(&validation_report) { return {}, false }
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		return {}, false
	}

	project := Project{hot_reload = default_hot_reload_settings(), gizmos = gizmos.default_settings()}
	if json.unmarshal(data, &project) != nil {
		return {}, false
	}
	if json.unmarshal(data, &project.raw_json) != nil {
		return {}, false
	}
	for layer_name, layer_index in project.layers {
		if layer_name == "Default" || layer_index == ecs.Default_Layer || layer_index >= 64 {
			return {}, false
		}
	}
	if project.hot_reload.poll_interval_ms <= 0 {
		project.hot_reload.poll_interval_ms = 250
	}

	return project, true
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
		return {}, false
	}
	project_directory, _ := filepath.split(project_path)
	input_path := project.input
	if len(input_path) > 0 {
		input_path, _ = filepath.join({project_directory, input_path})
	}
	input_data, input_ok := input.load(input_path)
	if !input_ok { return {}, false }

	title, _ := strings.clone_to_cstring(project.window.title)
	if project.window.msaa_4x {
		rl.SetConfigFlags({rl.ConfigFlag.MSAA_4X_HINT})
	}
	rl.InitWindow(project.window.width, project.window.height, title)
	if project.window.vsync {
		rl.SetTargetFPS(60)
	}

	asset_manager := assets.init(project_directory)
	audio_system := audio.init(project_directory)
	return Engine{project = project, registry = registry, assets = asset_manager, audio = audio_system, gizmos = project.gizmos, console = console.init(), input = input_data, systems = make([dynamic]System), scene_watches = make(map[string]map[string]i64), is_running = true}, true
}

// input_state exposes project-defined input actions and axes to game systems.
input_state :: proc(engine: ^Engine) -> ^input.Input { return &engine.input }

// project_json exposes the full root project.json document, including
// game-defined fields that are not part of Rune's typed Project settings.
project_json :: proc(engine: ^Engine) -> json.Value { return engine.project.raw_json }

// project_value returns a top-level project.json value by key. Use this for
// game-owned global settings while keeping Rune's required settings typed.
project_value :: proc(engine: ^Engine, key: string) -> (json.Value, bool) {
	object, ok := engine.project.raw_json.(json.Object)
	if !ok { return {}, false }
	value, found := object[key]
	return value, found
}

// developer_console exposes the engine-owned runtime console. Register
// project-specific commands and write diagnostic messages through this value.
developer_console :: proc(engine: ^Engine) -> ^console.Console { return &engine.console }

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

// draw_gizmos renders the runtime debug overlay for callback-based programs
// using rune.run. Programs using rune.run_scene get this call automatically
// after registered draw systems.
draw_gizmos :: proc(engine: ^Engine, world: ^ecs.World) {
	gizmos.draw_scene(world, engine.gizmos)
}

// AudioPlayer is repeatable, so playback commands address an entity and its
// stable component instance name.
// The engine owns the audio device and per-entity raylib sound instances.
play_audio :: proc(engine: ^Engine, world: ^ecs.World, entity: ecs.Entity, instance_name: string) -> bool {
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
	if len(system.name) == 0 { return false }
	for registered in engine.systems {
		if registered.name == system.name { return false }
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
		engine.active_scene_path = path
		watch_scene(engine, path)
	}
	return world, loaded
}

// reload_scene_if_changed updates a loaded World when its scene or a directly
// referenced prefab changes. Component-value-only scene saves are applied onto
// the existing World and return false so cached Entity handles stay valid and
// reload callbacks do not run. Structural changes still rebuild the World and
// return true; game code must reacquire cached entity IDs after that.
reload_scene_if_changed :: proc(engine: ^Engine, world: ^ecs.World, path: string) -> bool {
	if !engine.project.hot_reload.enabled || !engine.project.hot_reload.scenes || !engine.hot_reload_due || !scene_changed(engine, path) { return false }
	reloaded, loaded := scene.load_with_layers(path, &engine.registry, engine.project.layers)
	if !loaded { return false }
	if ecs.apply_value_snapshot(world, &reloaded) {
		watch_scene(engine, path)
		return false
	}
	ecs.physics_2d_shutdown(world)
	world^ = reloaded
	watch_scene(engine, path)
	return true
}

watch_scene :: proc(engine: ^Engine, path: string) {
	paths, found := scene.dependency_paths(path)
	if !found { return }
	watch := make(map[string]i64)
	for dependency_path in paths {
		if dependency_path != path && !engine.project.hot_reload.prefabs { continue }
		watch[dependency_path] = file_modified_time(dependency_path)
	}
	engine.scene_watches[path] = watch
}

scene_changed :: proc(engine: ^Engine, path: string) -> bool {
	watch, found := engine.scene_watches[path]
	if !found {
		watch_scene(engine, path)
		return false
	}
	for dependency_path, recorded_time in watch {
		if file_modified_time(dependency_path) != recorded_time { return true }
	}
	return false
}

file_modified_time :: proc(path: string) -> i64 {
	modified, err := os.modification_time_by_path(path)
	if err != nil { return -1 }
	return time.to_unix_nanoseconds(modified)
}

// run follows a familiar game-object lifecycle: on_update changes game state,
// then on_draw presents that state. Rendering is deliberately outside update so
// component systems never have to mix simulation with raylib draw calls.
run :: proc(engine: ^Engine, on_update: Update_Proc, on_draw: Draw_Proc) {
	defer shutdown(engine)

	for !rl.WindowShouldClose() {
		begin_frame(engine)
		on_update(engine)

		rl.BeginDrawing()
		clear_background(engine)
		on_draw(engine)
		console.draw(&engine.console)
		rl.EndDrawing()
	}
}

// run_scene drives registered systems against a loaded World. It preserves the
// callback-based run API for small programs while providing the normal ECS
// lifecycle for games. Scene reload notifications happen before update systems.
run_scene :: proc(engine: ^Engine, world: ^ecs.World) {
	defer ecs.physics_2d_shutdown(world)
	defer shutdown(engine)

	for !rl.WindowShouldClose() {
		begin_frame(engine)
		if len(engine.active_scene_path) > 0 && reload_scene_if_changed(engine, world, engine.active_scene_path) {
			run_scene_reload_systems(engine, world)
		}
		update_orbit_cameras_3d(engine, world)
		run_update_systems(engine, world)
		audio.update(&engine.audio, world)

		rl.BeginDrawing()
		clear_background(engine)
		run_draw_systems(engine, world)
		gizmos.draw_scene(world, engine.gizmos)
		console.draw(&engine.console)
		rl.EndDrawing()
	}
}

run_update_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	for system in engine.systems {
		if system.update != nil { system.update(engine, world) }
	}
}

run_draw_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	for system in engine.systems {
		if system.draw != nil { system.draw(engine, world) }
	}
}

run_scene_reload_systems :: proc(engine: ^Engine, world: ^ecs.World) {
	for system in engine.systems {
		if system.on_scene_reloaded != nil { system.on_scene_reloaded(engine, world) }
	}
}

update_orbit_cameras_3d :: proc(engine: ^Engine, world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "OrbitCamera3D") {
		orbit, has_orbit := ecs.get_orbit_camera_3d(world, entity)
		camera, has_camera := ecs.get_camera_3d(world, entity)
		if !has_orbit || !has_camera { continue }
		transform := ecs.update_orbit_camera_3d(&orbit, &engine.input, engine.delta_time)
		camera.target = orbit.target
		ecs.set_orbit_camera_3d(world, entity, orbit)
		ecs.set_transform(world, entity, transform)
		ecs.set_camera_3d(world, entity, camera)
	}
}

begin_frame :: proc(engine: ^Engine) {
	engine.delta_time = rl.GetFrameTime()
	if engine.delta_time > Max_Simulation_Delta {
		engine.delta_time = Max_Simulation_Delta
	}
	engine.hot_reload_due = hot_reload_poll_due(engine)
	if engine.hot_reload_due && engine.project.hot_reload.enabled && engine.project.hot_reload.textures {
		assets.refresh(&engine.assets)
	}
	if engine.hot_reload_due && engine.project.hot_reload.enabled && engine.project.hot_reload.models {
		assets.refresh_models(&engine.assets)
	}
	if engine.hot_reload_due && engine.project.hot_reload.enabled && engine.project.hot_reload.materials {
		assets.refresh_materials(&engine.assets)
	}
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

clear_background :: proc(engine: ^Engine) {
	rl.ClearBackground(rl.Color{
		engine.project.background_color[0],
		engine.project.background_color[1],
		engine.project.background_color[2],
		engine.project.background_color[3],
	})
}

hot_reload_poll_due :: proc(engine: ^Engine) -> bool {
	if !engine.project.hot_reload.enabled { return false }
	engine.hot_reload_elapsed += engine.delta_time
	interval := f32(engine.project.hot_reload.poll_interval_ms) / 1000
	if engine.hot_reload_elapsed < interval { return false }
	engine.hot_reload_elapsed = 0
	return true
}

shutdown :: proc(engine: ^Engine) {
	if engine.is_running {
		audio.shutdown(&engine.audio)
		assets.shutdown(&engine.assets)
		rl.CloseWindow()
		engine.is_running = false
	}
}
