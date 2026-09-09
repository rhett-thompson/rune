package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rune "rune:core"
import "rune:ecs"
import "rune:prefab"
import "rune:scene"
import "rune:validation"

Fixture :: "tools/prefab_validation/fixtures/controllers.scene.json"

validate_composition :: proc(registry: ^ecs.Component_Registry) {
	assert(ecs.register_data_component(registry, "ControllerSettings", "Custom controller data"))
	layers := make(map[string]u8)
	 layers["Gameplay"] = 1
	defer delete(layers)
	w, ok := scene.load_with_layers(Fixture, registry, layers)
	if !ok {fmt.eprintln(scene.last_load_error())}
	assert(ok)
	defer ecs.destroy(&w)
	assert(w.entity_count == 8)
	source_entities := w.scene_json.(json.Object)["entities"].(json.Array)
	assert(source_entities[0].(json.Object)["prefab"].(json.String) == "rig/fast.prefab.json", "preserve authored scene JSON")
	player := required_entity(&w, "player")
	other := required_entity(&w, "other")
	camera := required_entity(&w, "player/camera")
	accessory := required_entity(&w, "player/camera/accessory")
	other_camera := required_entity(&w, "other/camera")
	assert(w.parents[player] == 0, "controller motor remains unparented")
	assert(w.parents[camera] == player && w.parents[accessory] == camera)
	assert(w.layer_masks[camera] == 2 && w.layer_masks[accessory] == 2)
	assert(w.layer_masks[required_entity(&w, "player/visual")] == ecs.Default_Layer_Mask)
	assert(ecs.has_tag(&w, camera, "view"))
	assert(w.entity_names[camera] == "Player Camera")
	assert(!ecs.is_enabled(&w, accessory))
	assert(ecs.is_enabled(&w, required_entity(&w, "other/camera/accessory")))
	assert(!ecs.has_component_data(&w, player, "PrefabMarker"))
	assert(!ecs.has_component_data(&w, accessory, "PrefabMarker"))
	assert(ecs.has_component_data(&w, other, "PrefabMarker"))
	pose, has_pose := ecs.get_transform(&w, player)
	assert(has_pose && pose.position == [3]f32{3,0,0} && pose.rotation == [3]f32{0,25,0})
	motor, has_motor := ecs.get_character_controller_3d(&w, player)
	assert(has_motor && motor.move_speed == 9 && motor.jump_speed == 8)
	view, has_view := ecs.get_camera_3d(&w, camera)
	assert(has_view && view.fovy == 95 && view.active)
	other_view, _ := ecs.get_camera_3d(&w, other_camera)
	assert(other_view.fovy == 70, "instance overrides must not mutate the shared base")
	settings := w.component_data["ControllerSettings"][player].(json.Object)
	look := settings["look"].(json.Object)
	assert(look["sensitivity"].(json.Float) == 0.3 && look["invert"].(json.Boolean) == false)
	bindings := settings["bindings"].(json.Array)
	assert(len(bindings) == 1 && bindings[0].(json.String) == "forward")
	assert_asset_path(settings["file"], "tools/prefab_validation/fixtures/rig/controller.data")
	accessory_settings := w.component_data["ControllerSettings"][accessory].(json.Object)
	assert_asset_path(accessory_settings["file"], "tools/prefab_validation/fixtures/rig/parts/accessory.data")
	found_child, child_ok := ecs.find_prefab_child(&w, player, "camera/accessory")
	assert(child_ok && found_child == accessory)
	_, wrong := ecs.find_prefab_child(&w, other, "camera/missing")
	assert(!wrong)
	ref, ref_ok := ecs.entity_ref(&w, accessory)
	assert(ref_ok && ref.id == "player/camera/accessory")

	dependencies, deps_ok := scene.dependency_paths(Fixture)
	assert(deps_ok && len(dependencies) == 8)
	defer scene.destroy_dependency_paths(dependencies)
	nested_found := false
	for path in dependencies {if strings.has_suffix(path, "accessory.prefab.json") {nested_found = true}}
	assert(nested_found)

	// Fully identified prefab trees support non-structural snapshot reloads.
	snapshot, snapshot_ok := scene.load_with_layers(Fixture, registry, layers)
	assert(snapshot_ok)
	defer ecs.destroy(&snapshot)
	view.fovy = 85
	assert(ecs.set_camera_3d(&w, camera, view))
	assert(ecs.apply_value_snapshot(&w, &snapshot))
	assert(required_entity(&w, "player/camera") == camera)
	reloaded_view, _ := ecs.get_camera_3d(&w, camera)
	assert(reloaded_view.fovy == 85)

	validate_typed_scene(registry)
	validate_override_order(registry)
	validate_bad_composition(registry)
	validate_prefab_reload(registry)
	fmt.println("Prefab composition validation passed")
}

required_entity :: proc(world: ^ecs.World, id: string) -> ecs.Entity {
	entity, ok := ecs.find_entity_by_id(world, id)
	assert(ok, id)
	return entity
}

assert_asset_path :: proc(value: json.Value, relative: string) {
	expected, error := filepath.abs(relative)
	assert(error == nil)
	defer delete(expected)
	assert(value.(json.String) == expected)
}

validate_typed_scene :: proc(registry: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	// An explicitly false Maybe(bool) must survive the typed JSON round trip.
	children := []scene.Entity_Data{{id = "scene_camera"}}
	entities := []scene.Entity_Data{{id = "typed", prefab = "rig/controller.prefab.json", enabled = false, children = children}}
	assert(scene.instantiate_with_layers_at(&w, registry, {name = "Typed", entities = entities}, nil, "tools/prefab_validation/fixtures"))
	root := required_entity(&w, "typed")
	assert(!ecs.is_enabled(&w, root))
	assert(!ecs.is_enabled(&w, required_entity(&w, "typed/camera")))
	assert(w.parents[required_entity(&w, "scene_camera")] == root, "legacy scene-authored child IDs stay global")
}

validate_override_order :: proc(registry: ^ecs.Component_Registry) {
	data := `{
        "name":"Override order", "entities":[{
            "id":"p", "prefab":"rig/controller.prefab.json",
            "component_overrides":{"ControllerSettings":{"file":"prefab://scene.data"}},
            "child_overrides":{
                "camera/accessory":{"component_overrides":{"Transform":{"position":[2,0,0]}}},
                "camera":{"child_overrides":{"accessory":{"component_overrides":{"Transform":{"position":[1,0,0]}}}}}
            }
        }]
    }`
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	value: json.Value
	assert(json.unmarshal(transmute([]u8)data, &value, allocator = allocator) == nil)
	resolved := prefab.resolve_scene(value, Fixture, allocator)
	assert(resolved.error == "")
	w := ecs.init()
	defer ecs.destroy(&w)
	assert(scene.instantiate_resolved(&w, registry, resolved.value, nil, allocator))
	pose, has_pose := ecs.get_transform(&w, required_entity(&w, "p/camera/accessory"))
	assert(has_pose && pose.position == [3]f32{2,0,0}, "direct descendant patch follows parent patch")
	settings := w.component_data["ControllerSettings"][required_entity(&w, "p")].(json.Object)
	assert_asset_path(settings["file"], "tools/prefab_validation/fixtures/scene.data")
	// Resolving must not expand asset strings or mutate fields in the input document.
	root := value.(json.Object)["entities"].(json.Array)[0].(json.Object)
	assert(root["component_overrides"].(json.Object)["ControllerSettings"].(json.Object)["file"].(json.String) == "prefab://scene.data")
}

validate_bad_composition :: proc(registry: ^ecs.Component_Registry) {
	w, ok := scene.load("tools/prefab_validation/fixtures/cycle.scene.json", registry)
	assert(!ok && strings.contains(scene.last_load_error(), "cyclic prefab"))
	assert(w.entity_count == 0)
	_, deps_ok := scene.dependency_paths("tools/prefab_validation/fixtures/cycle.scene.json")
	assert(!deps_ok)
	bad_cases := []struct{json, error: string}{
		{`{"id":"p","prefab":"rig/controller.prefab.json","child_overrides":{"missing":{"enabled":false}}}`, "does not exist"},
		{`{"id":"p","prefab":"rig/controller.prefab.json","child_overrides":{"camera":{"id":"renamed"}}}`, "unsupported child override"},
		{`{"id":"p","prefab":"rig/controller.prefab.json","component_overrides":{"Missing":{}}}`, "missing component"},
		{`{"id":"p","prefab":"rig/controller.prefab.json","remove_components":["Missing"]}`, "missing component"},
		{`{"id":"p","prefab":"absent.prefab.json"}`, "could not read prefab"},
		{`{"id":"p","prefab":"rig/controller.prefab.json","children":[{"id":"camera"}]}`, "duplicate child ID"},
		{`{"prefab":"rig/controller.prefab.json"}`, "require IDs"},
		{`{"id":"p","components":[],"children":[]}`, "components must be an object"},
		{`{"id":"p","prefab":"rig/controller.prefab.json","component_overrides":{"Camera3D":null}}`, "missing component"},
	}
	for test in bad_cases {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		allocator := mem.dynamic_arena_allocator(&arena)
		value: json.Value
		encoded := strings.concatenate({`{"name":"Bad","entities":[`, test.json, `]}`}, allocator)
		parse_error := json.unmarshal(transmute([]u8)encoded, &value, allocator = allocator)
		if parse_error != nil {fmt.eprintln(encoded, parse_error)}
		assert(parse_error == nil)
		result := prefab.resolve_scene(value, Fixture, allocator)
		if !strings.contains(result.error, test.error) {fmt.eprintln(result.error, " expected ", test.error)}
		assert(strings.contains(result.error, test.error))
		mem.dynamic_arena_destroy(&arena)
	}
	// Validation runs on effective values: partial patches may omit required fields,
	// but invalid merged built-ins must still be rejected before a World is created.
	bad_file := "build/prefab-invalid.scene.json"
	bad_data := `{"name":"Invalid","entities":[{"id":"p","prefab":"../tools/prefab_validation/fixtures/rig/controller.prefab.json","component_overrides":{"CharacterController3D":{"radius":-1}}}]}`
	assert(os.write_entire_file(bad_file, transmute([]u8)bad_data) == nil)
	report := validation.validate_scene(bad_file)
	assert(!validation.is_valid(&report))
	validation.destroy_report(&report)
	_, loaded := scene.load(bad_file, registry)
	assert(!loaded)
	assert(os.write_entire_file(bad_file, `{"name":"Duplicate","entities":[{"id":"p","prefab":"../tools/prefab_validation/fixtures/rig/controller.prefab.json"},{"id":"p/camera"}]}`) == nil)
	_, loaded = scene.load(bad_file, registry)
	assert(!loaded && strings.contains(scene.last_load_error(), "duplicates another entity ID"))
	assert(os.write_entire_file("build/prefab-bad-id.prefab.json", `{"name":"Bad ID","components":{},"children":[{"id":"bad/id"}]}`) == nil)
	report = validation.init_report()
	validation.validate_prefab(&report, "build/prefab-bad-id.prefab.json", "")
	assert(!validation.is_valid(&report) && strings.contains(report.diagnostics[0].message, "without '/'"))
	validation.destroy_report(&report)
}

validate_prefab_reload :: proc(registry: ^ecs.Component_Registry) {
	// Exercise the production scene polling path without a graphics context.
	scene_file := "build/prefab-reload.scene.json"
	child_file := "build/prefab-reload-child.prefab.json"
	parent_file := "build/prefab-reload-parent.prefab.json"
	assert(os.write_entire_file(scene_file, `{"name":"Reload","entities":[{"id":"player","prefab":"prefab-reload-parent.prefab.json"}]}`) == nil)
	assert(os.write_entire_file(parent_file, `{"name":"Parent","components":{},"children":[{"id":"camera","prefab":"prefab-reload-child.prefab.json"}]}`) == nil)
	assert(os.write_entire_file(child_file, `{"name":"Camera","components":{"Camera3D":{"fovy":70}}}`) == nil)
	before, before_ok := scene.load(scene_file, registry)
	assert(before_ok)
	defer ecs.destroy(&before)
	engine: rune.Engine
	engine.registry = registry^
	engine.project.hot_reload = {enabled = true, scenes = true, prefabs = true}
	engine.hot_reload_due = true
	engine.scene_watches = make(map[string]map[string]i64)
	defer {
		for path, watch in engine.scene_watches {rune.destroy_scene_watch(watch); delete(path)}
		delete(engine.scene_watches)
	}
	rune.watch_scene(&engine, scene_file)
	paths, paths_ok := scene.dependency_paths(scene_file)
	assert(paths_ok && len(paths) == 3)
	scene.destroy_dependency_paths(paths)
	assert(os.write_entire_file(child_file, `{"name":"Camera","components":{"Camera3D":{"fovy":90}}}`) == nil)
	// Force only the child's recorded timestamp stale; avoid filesystem clock sleeps.
	child_absolute, path_error := filepath.abs(child_file)
	assert(path_error == nil)
	defer delete(child_absolute)
	watch := engine.scene_watches[scene_file]
	assert(len(watch) == 3)
	watch[child_absolute] = -2
	assert(rune.scene_changed(&engine, scene_file))
	camera := required_entity(&before, "player/camera")
	assert(!rune.reload_scene_if_changed(&engine, &before, scene_file), "value edits preserve handles")
	assert(required_entity(&before, "player/camera") == camera)
	assert(!rune.scene_changed(&engine, scene_file))
	view, _ := ecs.get_camera_3d(&before, camera)
	assert(view.fovy == 90)
	assert(os.write_entire_file(child_file, `{"name":"Broken","prefab":"prefab-reload-parent.prefab.json"}`) == nil)
	watch = engine.scene_watches[scene_file]
	watch[child_absolute] = -2
	assert(!rune.reload_scene_if_changed(&engine, &before, scene_file))
	assert(strings.contains(scene.last_load_error(), "cyclic prefab"))
	view, _ = ecs.get_camera_3d(&before, camera)
	assert(view.fovy == 90)
	assert(os.write_entire_file(child_file, `{"name":"Repaired Camera","components":{"Camera3D":{"fovy":75}}}`) == nil)
	assert(!rune.reload_scene_if_changed(&engine, &before, scene_file))
	view, _ = ecs.get_camera_3d(&before, camera)
	assert(view.fovy == 75)
}
