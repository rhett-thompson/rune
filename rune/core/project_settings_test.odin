package core

import "core:fmt"
import "core:os"
import "core:testing"
import "rune:console"
import "rune:ecs"
import "rune:render"
import "rune:save"
import b3 "vendor:box3d"

@(test)
project_3d_settings_decode_defaults_and_partial_overrides :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("build", "project-3d-settings-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := fmt.tprintf("%s/project.json", directory)
	defer os.remove(path)
	documents := []string{
		`{"name":"Defaults","window":{}}`,
		`{"name":"Empty","window":{},"physics_3d":{},"render_3d":{"shadows":{}}}`,
		`{"name":"Partial","window":{},"physics_3d":{"worker_count":3},"render_3d":{"shadows":{"spot_resolution":512}}}`,
		`{"name":"Whole floats","window":{},"physics_3d":{"worker_count":2.0},"render_3d":{"shadows":{"omni_resolution":128.0}}}`,
		`{"name":"Workers","window":{},"jobs":{"worker_count":3}}`,
		`{"name":"Queue","window":{},"jobs":{"queue_capacity":1}}`,
	}
	for document, index in documents {
		assert(os.write_entire_file(path, document) == nil)
		project, loaded := load_project(path)
		if !testing.expect(t, loaded, "valid project settings must decode") {continue}
		expected := render.Default_Settings_3D
		workers := 1
		if index == 2 {workers = 3; expected.shadows.spot_resolution = 512}
		if index == 3 {workers = 2; expected.shadows.omni_resolution = 128}
		testing.expect_value(t, project.physics_3d.worker_count, workers)
		testing.expect_value(t, project.render_3d, expected)
		testing.expect_value(t,project.jobs.worker_count,3 if index==4 else 0)
		testing.expect_value(t,project.jobs.queue_capacity,1 if index==5 else 256)
		destroy_project(&project)
	}
}

@(test)
project_physics_workers_survive_scene_replacement_paths :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("build", "project-physics-workers-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	project_path := fmt.tprintf("%s/project.json", directory)
	first_path := fmt.tprintf("%s/first.scene.json", directory)
	next_path := fmt.tprintf("%s/next.scene.json", directory)
	defer os.remove(project_path)
	defer os.remove(first_path)
	defer os.remove(next_path)
	defer os.remove(fmt.tprintf("%s/checkpoint.save.json", directory))
	assert(os.write_entire_file(project_path, `{"name":"Worker integration","window":{},"physics_3d":{"worker_count":3}}`) == nil)
	initial := `{"name":"Workers","entities":[{"id":"box","components":{"Transform":{"position":[0,3,0]},"BoxCollider":{"size":[1,1,1]},"RigidBody3D":{"body_type":"dynamic"}}}]}`
	structural := `{"name":"Workers","entities":[{"id":"box","components":{"Transform":{"position":[0,4,0]},"BoxCollider":{"size":[1,1,1]},"RigidBody3D":{"body_type":"dynamic"}}},{"id":"extra"}]}`
	assert(os.write_entire_file(first_path, initial) == nil)
	assert(os.write_entire_file(next_path, initial) == nil)
	project, loaded := load_project(project_path)
	if !testing.expect(t, loaded) {return}
	game := Engine{
		project = project, project_directory = directory,
		registry = ecs.init_registry(), scene_watches = make(map[string]map[string]i64),
		console = console.init(),
	}
	defer {
		if game.has_active_world {ecs.destroy(&game.active_world)}
		save.destroy(&game.saves)
		ecs.destroy_registry(&game.registry)
		paths := make([dynamic]string)
		for path, watch in game.scene_watches {append(&paths, path); destroy_scene_watch(watch)}
		delete(game.scene_watches)
		for path in paths {delete(path)}
		delete(paths)
		destroy_project(&game.project)
	}
	assert(ecs.register_builtin_components(&game.registry))
	active_loaded := load_active_scene(&game, "first.scene.json")
	if !testing.expect(t, active_loaded, last_scene_error()) {return}
	project_workers_expect_native(t, &game)
	if !testing.expect(t, change_scene(&game, "next.scene.json")) {return}
	project_workers_expect_native(t, &game)
	when !Player_Build {
		assert(os.write_entire_file(next_path, structural) == nil)
		watch := game.scene_watches[game.active_scene_path]
		for path in watch {
			watch[path] = -1
		}
		game.hot_reload_due = true
		generation := game.active_world.generation
		testing.expect(t, reload_scene_if_changed(&game, &game.active_world, game.active_scene_path))
		testing.expect(t, game.active_world.generation != generation)
		project_workers_expect_native(t, &game)
		bind_debug_console(&game, &game.active_world)
		reload_command(&game.console, "")
		project_workers_expect_native(t, &game)
	}
	// Save-enabled transitions take a separate prepare/apply/publish path.
	if !testing.expect(t, configure_saves(&game, {game_id="worker-test", game_version=1, directory=directory})) {return}
	if !testing.expect(t, request_saved_scene(&game, "first.scene.json")) {return}
	process_save_requests(&game)
	testing.expect(t, game.save_result.ok)
	project_workers_expect_native(t, &game)
	if !testing.expect(t, request_save(&game, "checkpoint")) {return}
	process_save_requests(&game)
	testing.expect(t, game.save_result.ok)
	if !testing.expect(t, request_saved_scene(&game, "next.scene.json")) {return}
	process_save_requests(&game)
	testing.expect(t, game.save_result.ok)
	project_workers_expect_native(t, &game)
	if !testing.expect(t, request_load(&game, "checkpoint")) {return}
	process_save_requests(&game)
	testing.expect(t, game.save_result.ok)
	project_workers_expect_native(t, &game)
}

project_workers_expect_native :: proc(t: ^testing.T, game: ^Engine) {
	testing.expect_value(t, game.active_world.physics_3d_worker_count, 3)
	ecs.physics_3d_update(&game.active_world, 1.0 / 60.0)
	if !testing.expect(t, !b3.IS_NULL(game.active_world.box3d_world)) {return}
	testing.expect_value(t, b3.World_GetWorkerCount(game.active_world.box3d_world), i32(3))
}
