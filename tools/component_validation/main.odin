package main

import "core:encoding/json"
import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:scene"

Typed_Nested_Test :: struct {
	amount: i32,
}

Typed_Component_Test :: struct {
	speed:        f32,
	display_name: string `json:"displayName"`,
	nested:       Typed_Nested_Test,
}

main :: proc() {
	validate_project_ownership()
	validate_strict_component_registration()
	validate_entity_metadata()
	validate_reflected_typed_components()
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	assert(ecs.register_data_component(&registry, "Greeting", "Hello-world validation data"))
	project, project_loaded := rune.load_project("examples/hello_world/project.json")
	assert(project_loaded)
	defer rune.destroy_project(&project)
	assert(project.hot_reload.enabled && project.hot_reload.poll_interval_ms == 250)
	assert(
		project.hot_reload.scenes &&
		project.hot_reload.prefabs &&
		project.hot_reload.textures &&
		project.hot_reload.models,
	)
	world, loaded := scene.load_with_layers(
		"examples/hello_world/scenes/main.scene.json",
		&registry,
		project.layers,
	)
	assert(loaded)

	greeting, found := ecs.find_entity_by_id(&world, "greeting")
	assert(found)
	transform, has_transform := ecs.get_transform(&world, greeting)
	assert(has_transform)
	assert(transform.position == [3]f32{64, 64, 0})

	transform.position[0] += 10
	assert(ecs.set_transform(&world, greeting, transform))
	validate_mesh_renderer()
	validate_sphere_renderer()
	validate_sphere_collider()
	validate_model_renderer()
	validate_character_collision()
	validate_tilemap_renderer()
	validate_tilemap_collision()
	validate_text_renderer()
	validate_motion_components()
	validate_camera_components()
	validate_audio_components()
	validate_named_audio_instances()
	fmt.println("Typed built-in component validation passed")
}

validate_project_ownership :: proc() {
	for _ in 0 ..< 16 {
		project, loaded := rune.load_project("examples/hello_world/project.json")
		assert(loaded && project.name == "Rune Hello World")
		_, has_raw_json := project.raw_json.(json.Object)
		assert(has_raw_json)
		rune.destroy_project(&project)
		rune.destroy_project(&project)
	}
}

validate_strict_component_registration :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/hello_world/scenes/main.scene.json", &registry)
	assert(!loaded)
	assert(len(scene.last_load_error()) > 0)
	ecs.destroy(&world)
}

validate_reflected_typed_components :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(
		ecs.register_component_type(
			&registry,
			"TypedTest",
			Typed_Component_Test,
			Typed_Component_Test{speed = 4, display_name = "default", nested = {amount = 2}},
			"Reflected typed component validation",
		),
	)
	assert(
		!ecs.register_component_type(
			&registry,
			"TypedTest",
			Typed_Component_Test,
			Typed_Component_Test{},
		),
	)

	world := typed_test_world(&registry, `{"displayName":"live","nested":{"amount":3}}`)
	defer ecs.destroy(&world)
	entity, found := ecs.find_entity_by_id(&world, "typed")
	assert(found)
	component, typed_found := ecs.get(&world, entity, Typed_Component_Test)
	assert(typed_found)
	assert(component.speed == 4)
	assert(component.display_name == "live")
	assert(component.nested.amount == 3)
	assert(len(ecs.query(&world, Typed_Component_Test)) == 1)

	component.speed = 9
	before_set := ecs.change_version(&world)
	assert(ecs.set(&world, entity, component))
	component, typed_found = ecs.get(&world, entity, Typed_Component_Test)
	assert(typed_found && component.speed == 9)
	changes := ecs.changes_since(&world, Typed_Component_Test, before_set)
	assert(len(changes) == 1 && changes[0].entity == entity && changes[0].kind == .Changed)
	_, wrong_type_found := ecs.get(&world, entity, Typed_Nested_Test)
	assert(!wrong_type_found)

	unknown_world := ecs.init()
	defer ecs.destroy(&unknown_world)
	unknown_entity := ecs.create_entity(&unknown_world)
	assert(
		!ecs.add_component(
			&unknown_world,
			&registry,
			unknown_entity,
			"TypedTest",
			json_value(`{"speed":1,"unknown":true}`),
		),
	)
	assert(
		!ecs.add_component(
			&unknown_world,
			&registry,
			unknown_entity,
			"TypedTest",
			json_value(`{"nested":{"amount":1,"unknown":true}}`),
		),
	)
	assert(
		!ecs.add_component(
			&unknown_world,
			&registry,
			unknown_entity,
			"TypedTest",
			json_value(`{"Speed":1}`),
		),
	)

	snapshot := typed_test_world(
		&registry,
		`{"speed":12,"displayName":"reloaded","nested":{"amount":8}}`,
	)
	defer ecs.destroy(&snapshot)
	assert(ecs.apply_value_snapshot(&world, &snapshot))
	component, typed_found = ecs.get(&world, entity, Typed_Component_Test)
	assert(typed_found)
	assert(component.speed == 12)
	assert(component.display_name == "reloaded")
	assert(component.nested.amount == 8)

	runtime_entity := ecs.create_entity(&world)
	runtime_value := Typed_Component_Test {
		speed = 6,
		display_name = "runtime",
		nested = {amount = 7},
	}
	assert(ecs.add(&world, &registry, runtime_entity, runtime_value))
	runtime_component, runtime_found := ecs.get(&world, runtime_entity, Typed_Component_Test)
	assert(runtime_found && runtime_component == runtime_value)
	assert(ecs.add_resource(&world, Typed_Nested_Test{amount = 42}))
	resource, resource_found := ecs.resource(&world, Typed_Nested_Test)
	assert(resource_found && resource.amount == 42)
	before_destroy := ecs.change_version(&world)
	assert(ecs.destroy_entity(&world, runtime_entity))
	assert(!ecs.is_alive(&world, runtime_entity))
	removals := ecs.changes_since(&world, Typed_Component_Test, before_destroy)
	assert(len(removals) == 1 && removals[0].kind == .Removed)
}

typed_test_world :: proc(registry: ^ecs.Component_Registry, text: string) -> ecs.World {
	world := ecs.init()
	entity := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, entity, "typed", "Typed", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, registry, entity, "TypedTest", json_value(text)))
	return world
}

json_value :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]byte)text, &value) == nil)
	return value
}

validate_audio_components :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/audio_components/scenes/main.scene.json", &registry)
	assert(loaded)
	listener_entity, listener_found := ecs.find_entity_by_id(&world, "main_camera")
	assert(listener_found)
	active_entity, listener, active_found := ecs.active_audio_listener(&world)
	assert(active_found && active_entity == listener_entity && listener.active)
	player_entity, player_found := ecs.find_entity_by_id(&world, "bell_sphere")
	assert(player_found)
	player_names := ecs.component_instance_names(&world, player_entity, "AudioPlayer")
	assert(len(player_names) == 1 && player_names[0] == "bell")
	player, has_player := ecs.get_audio_player(&world, player_entity, "bell")
	assert(has_player && player.sound == "assets/bell.wav" && player.spatial && !player.looping)
	assert(
		player.volume == 0.35 &&
		player.pitch == 1.25 &&
		player.min_distance == 2 &&
		player.max_distance == 32,
	)
	assert(player.random_volume == 0 && player.random_pitch == 0.05)
	assert(player.max_voices == 3)
	assert(!player.play_on_start)
	assert(ecs.set_active_audio_listener(&world, listener_entity))
}

validate_entity_metadata :: proc() {
	validate_entity_id_index()
	project, project_loaded := rune.load_project("examples/hello_world/project.json")
	assert(project_loaded)
	defer rune.destroy_project(&project)
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	assert(ecs.register_data_component(&registry, "Greeting", "Hello-world validation data"))
	world, loaded := scene.load_with_layers(
		"examples/hello_world/scenes/main.scene.json",
		&registry,
		project.layers,
	)
	assert(loaded)
	greeting, greeting_found := ecs.find_entity_by_id(&world, "greeting")
	assert(greeting_found)
	id, has_id := ecs.entity_id(&world, greeting)
	assert(has_id && id == "greeting")
	assert(ecs.has_tag(&world, greeting, "ui"))
	assert(ecs.is_in_layer_mask(&world, greeting, u64(1) << 2))
	assert(!ecs.is_in_layer_mask(&world, greeting, u64(1) << 1))
}

validate_entity_id_index :: proc() {
	world := ecs.init()
	first := ecs.create_entity(&world)
	second := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, first, "player", "Player", "", ecs.Default_Layer_Mask))
	resolved, found := ecs.find_entity_by_id(&world, "player")
	assert(found && resolved == first)
	assert(
		!ecs.set_entity_metadata(
			&world,
			second,
			"player",
			"Other Player",
			"",
			ecs.Default_Layer_Mask,
		),
	)
	_, empty_found := ecs.find_entity_by_id(&world, "")
	assert(!empty_found)

	player_ref, ref_found := ecs.entity_ref(&world, first)
	assert(ref_found && player_ref.id == "player")

	reloaded_world := ecs.init()
	reloaded_player := ecs.create_entity(&reloaded_world)
	assert(
		ecs.set_entity_metadata(
			&reloaded_world,
			reloaded_player,
			"player",
			"Player",
			"",
			ecs.Default_Layer_Mask,
		),
	)
	assert(!ecs.is_alive(&reloaded_world, first))
	assert(ecs.entity_index(first) == ecs.entity_index(reloaded_player))
	assert(ecs.entity_generation(first) != ecs.entity_generation(reloaded_player))
	resolved_after_reload, resolved_after_reload_found := ecs.resolve_entity_ref(
		&reloaded_world,
		player_ref,
	)
	assert(resolved_after_reload_found && resolved_after_reload == reloaded_player)
	child := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, child, "child", "Child", "", ecs.Default_Layer_Mask))
	assert(ecs.set_parent(&world, child, first))
	assert(ecs.destroy_entity(&world, first))
	assert(!ecs.is_alive(&world, first) && !ecs.is_alive(&world, child))
	_, destroyed_id_found := ecs.find_entity_by_id(&world, "player")
	assert(!destroyed_id_found)
}

validate_named_audio_instances :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	assert(ecs.register_data_component(&registry, "TanksArena", "Ignored by audio validation"))
	assert(ecs.register_data_component(&registry, "Tank", "Ignored by audio validation"))
	assert(ecs.register_data_component(&registry, "TanksMatch", "Ignored by audio validation"))
	world, loaded := scene.load("examples/tanks/scenes/main.scene.json", &registry)
	assert(loaded)
	arena, found := ecs.find_entity_by_id(&world, "arena")
	assert(found)
	names := ecs.component_instance_names(&world, arena, "AudioPlayer")
	assert(len(names) == 5)
	expected_names := [5]string{"music", "ricochet", "tank_explode", "bullet_explode", "shoot"}
	for name in expected_names {
		player, instance_found := ecs.get_audio_player(&world, arena, name)
		assert(instance_found)
		assert(player.max_voices == 4)
	}
	assert(ecs.remove_component_instance(&world, arena, "AudioPlayer", "shoot"))
	_, shoot_found := ecs.get_audio_player(&world, arena, "shoot")
	assert(!shoot_found && ecs.has_component_data(&world, arena, "AudioPlayer"))
}

validate_camera_components :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/camera_switching/scenes/main.scene.json", &registry)
	assert(loaded)
	wide_camera, wide_found := ecs.find_entity_by_id(&world, "wide_camera")
	assert(wide_found)
	side_camera, side_found := ecs.find_entity_by_id(&world, "side_camera")
	assert(side_found)
	minimap_camera, minimap_found := ecs.find_entity_by_id(&world, "minimap_camera")
	assert(minimap_found)
	active, camera, active_found := ecs.active_camera_3d(&world)
	assert(active_found && active == wide_camera && camera.fovy == 45)
	assert(ecs.set_active_camera_3d(&world, side_camera))
	active, _, active_found = ecs.active_camera_3d(&world)
	assert(active_found && active == side_camera)
	camera_2d, has_camera_2d := ecs.get_camera_2d(&world, minimap_camera)
	assert(has_camera_2d && camera_2d.zoom == 0.2)
}

validate_mesh_renderer :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/hello_3d/scenes/main.scene.json", &registry)
	assert(loaded)
	cube, cube_found := ecs.find_entity_by_id(&world, "cube")
	assert(cube_found)
	mesh, mesh_found := ecs.get_mesh_renderer(&world, cube)
	assert(mesh_found && mesh.primitive == "cube")
}

validate_sphere_renderer :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/solar_system/scenes/main.scene.json", &registry)
	assert(loaded)
	sun, sun_found := ecs.find_entity_by_id(&world, "sun")
	assert(sun_found)
	sphere, sphere_found := ecs.get_sphere_renderer(&world, sun)
	assert(sphere_found && sphere.radius == 1.2)
}

validate_motion_components :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/solar_system/scenes/main.scene.json", &registry)
	assert(loaded)
	earth, earth_found := ecs.find_entity_by_id(&world, "earth")
	assert(earth_found)
	orbit, has_orbit := ecs.get_orbit(&world, earth)
	rotator, has_rotator := ecs.get_rotator(&world, earth)
	assert(has_orbit && orbit.degrees_per_second == 12)
	assert(has_rotator && rotator.degrees_per_second == 48)
	ecs.update_orbits(&world, 0.5)
	earth_transform, transform_found := ecs.get_transform(&world, earth)
	assert(transform_found && earth_transform.position[0] < 4 && earth_transform.position[2] > 0)
	ecs.update_rotators(&world, 0.5)
	earth_transform, transform_found = ecs.get_transform(&world, earth)
	assert(transform_found && earth_transform.rotation[1] == 24)
}

validate_sphere_collider :: proc() {
	project, project_loaded := rune.load_project("examples/third_person_3d/project.json")
	assert(project_loaded)
	defer rune.destroy_project(&project)
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load_with_layers(
		"examples/third_person_3d/scenes/main.scene.json",
		&registry,
		project.layers,
	)
	assert(loaded)
	target, found := ecs.find_entity_by_id(&world, "look_target")
	assert(found)
	collider, has_collider := ecs.get_sphere_collider(&world, target)
	assert(has_collider && collider.radius == 0.75 && collider.is_static)
	player, player_found := ecs.find_entity_by_id(&world, "player")
	assert(player_found)
	transform, has_transform := ecs.get_transform(&world, player)
	assert(has_transform)
	transform.position = {0, 0.75, -7.5}
	assert(ecs.set_transform(&world, player, transform))
	assert(ecs.move_character(&world, player, {0, -1}, false, 0.016))
	transform, has_transform = ecs.get_transform(&world, player)
	assert(has_transform && transform.position[2] == -7.5)
}

validate_model_renderer :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/model_scene_3d/scenes/main.scene.json", &registry)
	assert(loaded)
	pyramid, found := ecs.find_entity_by_id(&world, "pyramid")
	assert(found)
	model, has_model := ecs.get_model_renderer(&world, pyramid)
	assert(has_model && model.model == "assets/models/pyramid.obj")
	assert(model.tint == ecs.Color{255, 255, 255, 255})
}

validate_character_collision :: proc() {
	project, project_loaded := rune.load_project("examples/first_person_3d/project.json")
	assert(project_loaded)
	defer rune.destroy_project(&project)
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	assert(
		ecs.register_data_component(
			&registry,
			"FirstPersonController",
			"Ignored by collision validation",
		),
	)
	world, loaded := scene.load_with_layers(
		"examples/first_person_3d/scenes/main.scene.json",
		&registry,
		project.layers,
	)
	assert(loaded)
	player, found := ecs.find_entity_by_id(&world, "player")
	assert(found)
	controller, has_controller := ecs.get_character_controller(&world, player)
	assert(has_controller && controller.height == 1.8)
	floor, floor_found := ecs.find_entity_by_id(&world, "floor")
	assert(floor_found)
	_, has_floor_collider := ecs.get_box_collider(&world, floor)
	assert(has_floor_collider)
	assert(ecs.move_character(&world, player, {}, false, 0.016))
	player_transform, has_transform := ecs.get_transform(&world, player)
	assert(has_transform && player_transform.position[1] == 1.6)
	controller, has_controller = ecs.get_character_controller(&world, player)
	assert(has_controller && controller.grounded)
	assert(ecs.move_character(&world, player, {}, true, 0.1))
	player_transform, has_transform = ecs.get_transform(&world, player)
	assert(has_transform && player_transform.position[1] > 1.6)
}

validate_tilemap_renderer :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/tilemap_2d/scenes/main.scene.json", &registry)
	assert(loaded)
	tilemap_entity, found := ecs.find_entity_by_id(&world, "dungeon")
	assert(found)
	tilemap, has_tilemap := ecs.get_tilemap_renderer(&world, tilemap_entity)
	assert(has_tilemap)
	assert(tilemap.texture == "../sprite_scene_2d/assets/wallDark.png")
	assert(tilemap.tile_size == [2]f32{16, 16})
	assert(len(tilemap.tiles) > 0)
}

validate_tilemap_collision :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/tilemap_collision_2d/scenes/main.scene.json", &registry)
	assert(loaded)
	player, found := ecs.find_entity_by_id(&world, "player")
	assert(found)
	_, has_controller := ecs.get_top_down_controller(&world, player)
	assert(has_controller)
	dungeon, dungeon_found := ecs.find_entity_by_id(&world, "dungeon")
	assert(dungeon_found)
	_, has_collider := ecs.get_tilemap_collider(&world, dungeon)
	assert(has_collider)
	assert(ecs.move_top_down(&world, player, {-30, 0}))
	transform, has_transform := ecs.get_transform(&world, player)
	assert(has_transform && transform.position[0] == 72)
}

validate_text_renderer :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/tilemap_collision_2d/scenes/main.scene.json", &registry)
	assert(loaded)
	instructions, found := ecs.find_entity_by_id(&world, "instructions")
	assert(found)
	text, has_text := ecs.get_text_renderer(&world, instructions)
	assert(has_text && text.text == "WASD: move through the dungeon walls")
	assert(text.font == "../hello_world/assets/fonts/mecha.png" && text.font_size == 18)
}
