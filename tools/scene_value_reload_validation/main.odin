package main

import "core:fmt"
import "core:encoding/json"
import rune "rune:core"
import "rune:ecs"
import "rune:scene"

main :: proc() {
	validate_hello_world_value_reload()
	validate_textured_model_light_edit()
	fmt.println("Scene value reload validation passed")
}

validate_hello_world_value_reload :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	assert(ecs.register_data_component(&registry, "Greeting", "Hello-world reload validation data"))
	project, project_loaded := rune.load_project("examples/hello_world/project.json")
	assert(project_loaded)

	world, loaded := scene.load_with_layers("examples/hello_world/scenes/main.scene.json", &registry, project.layers)
	assert(loaded)
	snapshot, snapshot_loaded := scene.load_with_layers("examples/hello_world/scenes/main.scene.json", &registry, project.layers)
	assert(snapshot_loaded)

	greeting, found := ecs.find_entity_by_id(&world, "greeting")
	assert(found)
	transform, has_transform := ecs.get_transform(&snapshot, greeting)
	assert(!has_transform)

	snapshot_greeting, snapshot_found := ecs.find_entity_by_id(&snapshot, "greeting")
	assert(snapshot_found && snapshot_greeting != greeting)
	transform, has_transform = ecs.get_transform(&snapshot, snapshot_greeting)
	assert(has_transform)
	transform.position[0] += 32
	assert(ecs.set_transform(&snapshot, snapshot_greeting, transform))
	set_component_json(&snapshot, snapshot_greeting, "Transform", `{"position":[96,64,0]}`)

	assert(ecs.apply_value_snapshot(&world, &snapshot))
	greeting_after, found_after := ecs.find_entity_by_id(&world, "greeting")
	assert(found_after && greeting_after == greeting)
	updated_transform, updated := ecs.get_transform(&world, greeting)
	assert(updated && updated_transform.position[0] == transform.position[0])

	structural_snapshot, structural_loaded := scene.load_with_layers("examples/hello_world/scenes/main.scene.json", &registry, project.layers)
	assert(structural_loaded)
	_ = ecs.create_entity(&structural_snapshot)
	assert(!ecs.apply_value_snapshot(&world, &structural_snapshot))
}

validate_textured_model_light_edit :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))

	world, loaded := scene.load("examples/textured_model_3d/scenes/main.scene.json", &registry)
	assert(loaded)
	snapshot, snapshot_loaded := scene.load("examples/textured_model_3d/scenes/main.scene.json", &registry)
	assert(snapshot_loaded)

	camera, camera_found := ecs.find_entity_by_id(&world, "camera")
	crate, crate_found := ecs.find_entity_by_id(&world, "crate")
	light, light_found := ecs.find_entity_by_id(&world, "warm_point_light")
	assert(camera_found && crate_found && light_found)

	camera_transform, has_camera_transform := ecs.get_transform(&world, camera)
	assert(has_camera_transform)
	camera_transform.position = {10, 8, 9}
	assert(ecs.set_transform(&world, camera, camera_transform))

	crate_transform, has_crate_transform := ecs.get_transform(&world, crate)
	assert(has_crate_transform)
	crate_transform.rotation[1] = 42
	assert(ecs.set_transform(&world, crate, crate_transform))

	snapshot_light, snapshot_light_found := ecs.find_entity_by_id(&snapshot, "warm_point_light")
	assert(snapshot_light_found)
	light_transform, has_light_transform := ecs.get_transform(&snapshot, snapshot_light)
	assert(has_light_transform)
	light_transform.position[0] += 1
	assert(ecs.set_transform(&snapshot, snapshot_light, light_transform))
	set_component_json(&snapshot, snapshot_light, "Transform", `{"position":[4.2,1.75,1.25]}`)

	assert(ecs.apply_value_snapshot(&world, &snapshot))
	camera_after, _ := ecs.get_transform(&world, camera)
	crate_after, _ := ecs.get_transform(&world, crate)
	light_after, _ := ecs.get_transform(&world, light)
	assert(camera_after.position == camera_transform.position)
	assert(crate_after.rotation[1] == crate_transform.rotation[1])
	assert(light_after.position[0] == light_transform.position[0])
}

set_component_json :: proc(world: ^ecs.World, entity: ecs.Entity, component_name, text: string) {
	value: json.Value
	assert(json.unmarshal(transmute([]byte)text, &value) == nil)
	components := world.component_data[component_name]
	components[entity] = value
	world.component_data[component_name] = components
}
