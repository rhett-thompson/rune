package ecs

import "core:testing"
import b3 "vendor:box3d"

@(test)
physics_3d_worker_configuration_is_per_world_and_validated :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	world := init(); defer destroy(&world)
	other := init(); defer destroy(&other)
	uninitialized: World
	testing.expect(t, world.physics_3d_worker_count == 1 && other.physics_3d_worker_count == 1)
	testing.expect(t, !configure_physics_3d(nil, 4) && !configure_physics_3d(&uninitialized, 4))
	for invalid in ([3]int{-1, 0, Physics3D_Max_Workers+1}) {
		testing.expect(t, !configure_physics_3d(&world, invalid) && world.physics_3d_worker_count == 1,
			"invalid worker counts leave the current configuration unchanged")
	}
	testing.expect(t, configure_physics_3d(&world, Physics3D_Max_Workers))
	testing.expect(t, configure_physics_3d(&world, 4))
	ensure_box3d_world(&world)
	ensure_box3d_world(&other)
	testing.expect(t, b3.World_GetWorkerCount(world.box3d_world) == 4,
		"the bundled native library receives the configured worker count")
	testing.expect(t, b3.World_GetWorkerCount(other.box3d_world) == 1,
		"configuring one World leaves another World serial")
	testing.expect(t, configure_physics_3d(&world, 4))
	testing.expect(t, !configure_physics_3d(&world, 2) && world.physics_3d_worker_count == 4,
		"an existing native world keeps its initial configuration")
	testing.expect(t, b3.World_GetWorkerCount(world.box3d_world) == 4)
	previous := world.box3d_world
	physics_3d_shutdown(&world)
	testing.expect(t, b3.IS_NULL(world.box3d_world) && !b3.World_IsValid(previous))
	testing.expect(t, world.physics_3d_worker_count == 4,
		"native shutdown preserves the World's configuration for recreation")
	ensure_box3d_world(&world)
	testing.expect(t, b3.World_GetWorkerCount(world.box3d_world) == 4)
}

@(test)
physics_3d_workers_step_contacts_and_release_native_scheduler :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	world := init(); defer destroy(&world)
	registry := init_registry(); defer destroy_registry(&registry)
	assert(register_builtin_components(&registry))
	assert(configure_physics_3d(&world, 4))
	floor := create_entity(&world)
	assert(add(&world, &registry, floor, Transform{position={0,-0.5,0},scale={1,1,1}}))
	assert(add(&world, &registry, floor, BoxCollider{size={30,1,30},is_static=true,friction=0.8}))
	bodies: [64]Entity
	for &entity, index in bodies {
		entity = create_entity(&world)
		assert(add(&world, &registry, entity, Transform{
			position={f32(index%8)*1.5-5.25, 2+f32(index%3), f32(index/8)*1.5-5.25},scale={1,1,1},
		}))
		assert(add(&world, &registry, entity, BoxCollider{size={0.5,0.5,0.5},friction=0.8}))
		assert(add(&world, &registry, entity, RigidBody3D{body_type="dynamic",gravity_scale=1}))
	}
	contacts := 0
	for _ in 0..<150 {
		physics_3d_update(&world, Physics3D_Fixed_Delta)
		for event in physics_3d_events(&world) {
			if event.kind == .Begin && !event.is_sensor && (event.a.entity == floor || event.b.entity == floor) {
				contacts += 1
			}
		}
	}
	testing.expect(t, b3.World_GetWorkerCount(world.box3d_world) == 4)
	testing.expect(t, contacts >= len(bodies), "worker stepping publishes native contact events at the fixed-step boundary")
	for entity in bodies {
		pose, found := get_transform(&world, entity)
		testing.expect(t, found && abs(pose.position.y-0.25) < 0.05,
			"dynamic bodies fall onto the floor and synchronize their resting poses")
	}
	pose, _ := get_transform(&world, bodies[0])
	hit, found := physics_3d_raycast(&world, pose.position+[3]f32{0,1,0}, {0,-2,0})
	testing.expect(t, found && hit.entity == bodies[0], "queries remain available after the worker step completes")
	previous := world.box3d_world
	physics_3d_shutdown(&world)
	testing.expect(t, !b3.World_IsValid(previous), "shutdown destroys the native world and joins its scheduler")
	physics_3d_update(&world, Physics3D_Fixed_Delta)
	testing.expect(t, b3.World_GetWorkerCount(world.box3d_world) == 4,
		"a fresh native scheduler can be created after shutdown")
}
