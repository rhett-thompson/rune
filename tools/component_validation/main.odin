package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:scene"

main :: proc() {
	validate_entity_metadata()
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	project, project_loaded := rune.load_project("examples/hello_world/project.json")
	assert(project_loaded)
	assert(project.hot_reload.enabled && project.hot_reload.poll_interval_ms == 250)
	assert(project.hot_reload.scenes && project.hot_reload.prefabs && project.hot_reload.textures && project.hot_reload.models)
	world, loaded := scene.load_with_layers("examples/hello_world/scenes/main.scene.json", &registry, project.layers)
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
	validate_model_renderer()
	validate_character_collision()
	validate_motion_components()
	validate_camera_components()
	validate_audio_components()
	fmt.println("Typed built-in component validation passed")
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
	player, has_player := ecs.get_audio_player(&world, player_entity)
	assert(has_player && player.sound == "assets/bell.wav" && player.spatial && !player.looping)
	assert(player.volume == 0.35 && player.pitch == 1.25 && player.min_distance == 2 && player.max_distance == 32)
	assert(!player.play_on_start)
	assert(ecs.set_active_audio_listener(&world, listener_entity))
}

validate_entity_metadata :: proc() {
	validate_entity_id_index()
	project, project_loaded := rune.load_project("examples/hello_world/project.json")
	assert(project_loaded)
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load_with_layers("examples/hello_world/scenes/main.scene.json", &registry, project.layers)
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
	assert(!ecs.set_entity_metadata(&world, second, "player", "Other Player", "", ecs.Default_Layer_Mask))
	_, empty_found := ecs.find_entity_by_id(&world, "")
	assert(!empty_found)
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

validate_model_renderer :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/model_scene_3d/scenes/main.scene.json", &registry)
	assert(loaded)
	pyramid, found := ecs.find_entity_by_id(&world, "pyramid")
	assert(found)
	model, has_model := ecs.get_model_renderer(&world, pyramid)
	assert(has_model && model.model == "assets/models/pyramid.obj")
	assert(model.tint == ecs.Color{210, 220, 255, 255})
}

validate_character_collision :: proc() {
	project, project_loaded := rune.load_project("examples/first_person_3d/project.json")
	assert(project_loaded)
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load_with_layers("examples/first_person_3d/scenes/main.scene.json", &registry, project.layers)
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
