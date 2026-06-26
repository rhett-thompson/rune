package main

import "core:encoding/json"
import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:jsonutil"
import "rune:scene"

main :: proc() {
	project, project_loaded := rune.load_project("examples/physics_platformer_2d/project.json")
	assert(project_loaded)
	project_settings, has_project_settings := project.raw_json.(json.Object)["game_settings"]
	assert(has_project_settings)
	project_settings_object, project_settings_ok := project_settings.(json.Object)
	project_mode, project_mode_ok := project_settings_object["mode"].(json.String)
	assert(project_settings_ok && project_mode_ok && project_mode == "arcade")
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	layers := make(map[string]u8)
	layers["Gameplay"] = 1
	world, loaded := scene.load_with_layers("examples/physics_platformer_2d/scenes/main.scene.json", &registry, layers)
	assert(loaded)
	scene_settings, has_scene_settings := ecs.get_scene_value(&world, "scene_settings")
	assert(has_scene_settings)
	scene_settings_object, scene_settings_ok := scene_settings.(json.Object)
	spawn_label, spawn_label_ok := scene_settings_object["spawn_label"].(json.String)
	assert(scene_settings_ok && spawn_label_ok && spawn_label == "training")
	player, found := ecs.find_entity_by_id(&world, "player")
	assert(found)
	controller, has_controller := ecs.get_component(&world, player, "PlayerController")
	assert(has_controller)
	controller_object, controller_ok := controller.(json.Object)
	assert(controller_ok)
	jump_height, has_jump_height := controller_object["jump_height"]
	assert(has_jump_height)
	jump_height_value, jump_height_ok := jsonutil.number(jump_height)
	assert(jump_height_ok && jump_height_value > 0)
	for _ in 0..<180 { ecs.physics_2d_update(&world, 1.0 / 60.0) }
	body, has_body := ecs.get_rigid_body_2d(&world, player)
	transform, has_transform := ecs.get_transform(&world, player)
	assert(has_body && body.grounded)
	assert(has_transform && transform.position[1] < 480 && transform.position[1] > 400)
	ball, ball_found := ecs.find_entity_by_id(&world, "circle_ball")
	_, has_circle := ecs.get_circle_collider_2d(&world, ball)
	assert(ball_found && has_circle)
	body.velocity[1] = -240
	body.grounded = false
	assert(ecs.set_rigid_body_2d(&world, player, body))
	ecs.physics_2d_update(&world, 1.0 / 60.0)
	transform, has_transform = ecs.get_transform(&world, player)
	assert(has_transform && transform.position[1] < 460)
	fmt.println("2D physics validation passed")
}
