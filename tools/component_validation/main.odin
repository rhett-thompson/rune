package main

import "core:fmt"
import "engine:ecs"
import "engine:scene"

main :: proc() {
	loaded_scene, loaded := scene.load("examples/hello_world/scenes/main.scene.json")
	assert(loaded)

	world := ecs.init()
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	assert(scene.instantiate(&world, &registry, loaded_scene))

	transform, found := ecs.get_transform(&world, ecs.Entity(1))
	assert(found)
	assert(transform.position == [3]f32{64, 64, 0})

	transform.position[0] += 10
	assert(ecs.set_transform(&world, ecs.Entity(1), transform))
	validate_mesh_renderer()
	validate_sphere_renderer()
	fmt.println("Typed built-in component validation passed")
}

validate_mesh_renderer :: proc() {
	loaded_scene, loaded := scene.load("examples/hello_3d/scenes/main.scene.json")
	assert(loaded)
	world := ecs.init()
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	assert(scene.instantiate(&world, &registry, loaded_scene))
	mesh, found := ecs.get_mesh_renderer(&world, ecs.Entity(1))
	assert(found && mesh.primitive == "cube")
}

validate_sphere_renderer :: proc() {
	loaded_scene, loaded := scene.load("examples/solar_system/scenes/main.scene.json")
	assert(loaded)
	world := ecs.init()
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	assert(scene.instantiate(&world, &registry, loaded_scene))
	sphere, found := ecs.get_sphere_renderer(&world, ecs.Entity(1))
	assert(found && sphere.radius == 1.2)
}
