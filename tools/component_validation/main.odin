package main

import "core:fmt"
import "engine:ecs"
import "engine:scene"

main :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/hello_world/scenes/main.scene.json", &registry)
	assert(loaded)

	transform, found := ecs.get_transform(&world, ecs.Entity(1))
	assert(found)
	assert(transform.position == [3]f32{64, 64, 0})

	transform.position[0] += 10
	assert(ecs.set_transform(&world, ecs.Entity(1), transform))
	validate_mesh_renderer()
	validate_sphere_renderer()
	validate_motion_components()
	fmt.println("Typed built-in component validation passed")
}

validate_mesh_renderer :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/hello_3d/scenes/main.scene.json", &registry)
	assert(loaded)
	mesh, found := ecs.get_mesh_renderer(&world, ecs.Entity(1))
	assert(found && mesh.primitive == "cube")
}

validate_sphere_renderer :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/solar_system/scenes/main.scene.json", &registry)
	assert(loaded)
	sphere, found := ecs.get_sphere_renderer(&world, ecs.Entity(1))
	assert(found && sphere.radius == 1.2)
}

validate_motion_components :: proc() {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/solar_system/scenes/main.scene.json", &registry)
	assert(loaded)
	orbit, has_orbit := ecs.get_orbit(&world, ecs.Entity(2))
	rotator, has_rotator := ecs.get_rotator(&world, ecs.Entity(2))
	assert(has_orbit && orbit.degrees_per_second == 12)
	assert(has_rotator && rotator.degrees_per_second == 48)
	ecs.update_orbits(&world, 0.5)
	earth, found := ecs.get_transform(&world, ecs.Entity(2))
	assert(found && earth.position[0] < 4 && earth.position[2] > 0)
	ecs.update_rotators(&world, 0.5)
	earth, found = ecs.get_transform(&world, ecs.Entity(2))
	assert(found && earth.rotation[1] == 24)
}
