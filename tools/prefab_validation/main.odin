package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:scene"

main :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	assert(ecs.register_data_component(&registry, "PrefabMarker", "Prefab child marker"))
	world, loaded := scene.load("examples/prefabs_2d/scenes/main.scene.json", &registry)
	assert(loaded)
	defer ecs.destroy(&world)

	left, found := ecs.find_entity_by_id(&world, "skeleton_left")
	assert(found)
	assert(ecs.has_tag(&world, left, "enemy"))
	transform, has_transform := ecs.get_transform(&world, left)
	assert(has_transform)
	assert(transform.position == [3]f32{180, 270, 0})
	assert(transform.scale != [3]f32{2, 2, 1}) // Scene overrides the prefab default.
	sprite, has_sprite := ecs.get_sprite_renderer(&world, left)
	assert(has_sprite)
	assert(sprite.texture == "../sprite_scene_2d/assets/skeletonWarrior.png")
	assert(sprite.origin == [2]f32{0.5, 0.5})
	children := ecs.child_entities(&world, left)
	assert(len(children) == 1)
	child_name, has_child_name := ecs.entity_name(&world, children[0])
	assert(has_child_name && child_name == "Weapon Anchor")
	assert(ecs.has_component_data(&world, children[0], "PrefabMarker"))

	center, center_found := ecs.find_entity_by_id(&world, "skeleton_center")
	assert(center_found)
	center_transform, center_has_transform := ecs.get_transform(&world, center)
	assert(center_has_transform && center_transform.scale != [3]f32{2, 2, 1})

	project, project_loaded := rune.load_project("examples/prefabs_2d/project.json")
	assert(project_loaded)
	assert(project.hot_reload.enabled && project.hot_reload.poll_interval_ms == 250)
	assert(
		project.hot_reload.scenes &&
		project.hot_reload.prefabs &&
		project.hot_reload.textures &&
		project.hot_reload.models,
	)
	for _ in 0 ..< 16 {
		dependencies, dependencies_ok := scene.dependency_paths(
			"examples/prefabs_2d/scenes/main.scene.json",
		)
		assert(dependencies_ok && len(dependencies) == 4)
		scene.destroy_dependency_paths(dependencies)
	}

	fmt.println("Prefab validation passed")
}
