package core

import "core:encoding/json"
import "core:os"
import "core:strings"
import "engine:ecs"
import rl "vendor:raylib"

Window_Settings :: struct {
	width:      i32,
	height:     i32,
	title:      string,
	fullscreen: bool,
	vsync:      bool,
}

Project :: struct {
	name:          string,
	startup_scene: string,
	window:        Window_Settings,
	input:         string,
}

Engine :: struct {
	project:    Project,
	registry:   ecs.Component_Registry,
	delta_time: f32,
	is_running: bool,
}

Update_Proc :: #type proc(engine: ^Engine)
Draw_Proc   :: #type proc(engine: ^Engine)

load_project :: proc(path: string) -> (Project, bool) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		return {}, false
	}

	project: Project
	if json.unmarshal(data, &project) != nil {
		return {}, false
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

	registry := ecs.init_registry()
	if !ecs.register_builtin_components(&registry) {
		return {}, false
	}

	title, _ := strings.clone_to_cstring(project.window.title)
	rl.InitWindow(project.window.width, project.window.height, title)
	if project.window.vsync {
		rl.SetTargetFPS(60)
	}

	return Engine{project = project, registry = registry, is_running = true}, true
}

// component_registry exposes the engine-initialized registry. Built-in
// components are ready after init; games only register their own components.
component_registry :: proc(engine: ^Engine) -> ^ecs.Component_Registry {
	return &engine.registry
}

// run follows a familiar game-object lifecycle: on_update changes game state,
// then on_draw presents that state. Rendering is deliberately outside update so
// component systems never have to mix simulation with raylib draw calls.
run :: proc(engine: ^Engine, on_update: Update_Proc, on_draw: Draw_Proc) {
	defer shutdown(engine)

	for !rl.WindowShouldClose() {
		engine.delta_time = rl.GetFrameTime()
		on_update(engine)

		rl.BeginDrawing()
		rl.ClearBackground(rl.RAYWHITE)
		on_draw(engine)
		rl.EndDrawing()
	}
}

shutdown :: proc(engine: ^Engine) {
	if engine.is_running {
		rl.CloseWindow()
		engine.is_running = false
	}
}
