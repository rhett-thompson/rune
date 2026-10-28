package ecs

import "core:mem"
import "core:slice"
import "core:testing"
import "rune:jobs"
import "rune:navigation"

Navigation_Jobs_Fixture_3D :: struct {
	world: World,
	registry: Component_Registry,
	mesh: navigation.Mesh_3D,
	surface: Entity,
	agents: [12]Entity,
}

navigation_jobs_fixture_3d :: proc(controller: bool = false) -> Navigation_Jobs_Fixture_3D {
	f := Navigation_Jobs_Fixture_3D{world=init(), registry=init_registry()}
	assert(register_builtin_components(&f.registry))
	vertices := make([][3]f32, 49, context.temp_allocator)
	triangles := make([dynamic][3]i32, context.temp_allocator)
	for z in 0..<7 {for x in 0..<7 {vertices[z*7+x] = {f32(x)*2, 0, f32(z)*2}}}
	for z in 0..<6 {for x in 0..<6 {
		// Routes cross a triangulated surface and detour around a central hole.
		if x >= 2 && x < 4 && z >= 2 && z < 4 {continue}
		a := i32(z*7+x); b := a+1; c := a+8; d := a+7
		append(&triangles, [3]i32{a,b,c}, [3]i32{a,c,d})
	}}
	error: string
	f.mesh, error = navigation.build_mesh_3d({version=1, agent_radius=0.2, agent_height=2, vertices=vertices, triangles=triangles[:]})
	assert(error == "", error)
	f.surface = create_entity(&f.world)
	assert(set_entity_metadata(&f.world, f.surface, "jobs_surface", "", "", Default_Layer_Mask))
	assert(add(&f.world, &f.registry, f.surface, NavMesh3D{runtime=true}))
	assert(set_navigation_mesh_3d(&f.world, f.surface, f.mesh))
	if controller {
		floor := create_entity(&f.world)
		pose := default_transform(); pose.position = {6,-0.5,6}
		assert(add(&f.world, &f.registry, floor, pose))
		assert(add(&f.world, &f.registry, floor, BoxCollider{size={14,1,14}, is_static=true}))
	}
	for &entity, index in f.agents {
		entity = create_entity(&f.world)
		pose := default_transform(); pose.position = {1,0,1+f32(index)*0.75}
		assert(add(&f.world, &f.registry, entity, pose))
		config := default_nav_agent_3d(); config.mesh = {id="jobs_surface"}
		config.radius = 0.55; config.repath_interval = 0.03; config.drive_controller = controller
		config.update_rotation = true; config.auto_braking = true; config.acceleration = 8; config.braking = 10
		assert(add(&f.world, &f.registry, entity, config))
		if controller {assert(add(&f.world, &f.registry, entity, default_character_controller_3d()))}
		assert(set_navigation_target_3d(&f.world, entity, {11,0,11-f32(index)*0.75}))
	}
	return f
}

navigation_jobs_fixture_destroy_3d :: proc(f: ^Navigation_Jobs_Fixture_3D) {
	destroy(&f.world); destroy_registry(&f.registry)
	navigation.destroy_mesh_3d(&f.mesh)
	f^ = {}
}

navigation_jobs_expect_equal_3d :: proc(t: ^testing.T, serial, parallel: ^Navigation_Jobs_Fixture_3D) {
	for entity, index in serial.agents {
		other := parallel.agents[index]
		a, a_ok := get_navigation_state_3d(&serial.world, entity)
		b, b_ok := get_navigation_state_3d(&parallel.world, other)
		testing.expect(t, a_ok == b_ok)
		if !a_ok {continue}
		testing.expect(t, a.status == b.status && a.path_status == b.path_status && a.has_target == b.has_target && a.target == b.target &&
			a.desired_velocity == b.desired_velocity && a.actual_velocity == b.actual_velocity && a.remaining_distance == b.remaining_distance && a.next_point == b.next_point,
			"serial and worker batches publish identical navigation state")
		testing.expect(t, slice.equal(a.path, b.path), "path points retain deterministic ordering")
		x := serial.world.navigation_3d.agents[entity]; y := parallel.world.navigation_3d.agents[other]
		testing.expect(t, slice.equal(x.path.triangles, y.path.triangles), "triangle corridors match")
		pose, _ := get_transform(&serial.world, entity); other_pose, _ := get_transform(&parallel.world, other)
		testing.expect_value(t, pose, other_pose)
	}
}

@(test)
navigation_jobs_match_serial_paths_and_mutations_with_private_main_arena :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	// An arena is deliberately unsuitable for concurrent output allocation.
	// Workers must rehome final paths before returning to this allocator.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	pool := jobs.create(3, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	serial := navigation_jobs_fixture_3d(); defer navigation_jobs_fixture_destroy_3d(&serial)
	parallel := navigation_jobs_fixture_3d(); defer navigation_jobs_fixture_destroy_3d(&parallel)
	for step in 0..<18 {
		if step == 3 {
			for fixture in ([2]^Navigation_Jobs_Fixture_3D{&serial,&parallel}) {
				assert(set_navigation_target_3d(&fixture.world, fixture.agents[0], {10,0,1}))
				config, _ := get(&fixture.world, fixture.agents[1], NavAgent3D); config.radius = 0.65
				assert(set(&fixture.world, fixture.agents[1], config))
				pose, _ := get_transform(&fixture.world, fixture.agents[2]); pose.position = {2,0,10}
				assert(set_transform(&fixture.world, fixture.agents[2], pose))
				assert(set_enabled(&fixture.world, fixture.agents[3], false))
			}
		}
		if step == 6 || step == 8 {
			for fixture in ([2]^Navigation_Jobs_Fixture_3D{&serial,&parallel}) {
				assert(set_navigation_triangle_blocked_3d(&fixture.world, fixture.surface, 0, step == 6))
			}
		}
		if step == 4 || step == 9 {
			for fixture in ([2]^Navigation_Jobs_Fixture_3D{&serial,&parallel}) {
				config, _ := get(&fixture.world, fixture.agents[4], NavAgent3D)
				config.height = 3 if step == 4 else 1.8
				assert(set(&fixture.world, fixture.agents[4], config))
			}
		}
		if step == 10 {
			for fixture in ([2]^Navigation_Jobs_Fixture_3D{&serial,&parallel}) {
				assert(set_enabled(&fixture.world, fixture.agents[3], true))
				assert(clear_navigation_mesh_3d(&fixture.world, fixture.surface))
			}
		}
		if step == 11 {
			for fixture in ([2]^Navigation_Jobs_Fixture_3D{&serial,&parallel}) {
				assert(set_navigation_mesh_3d(&fixture.world, fixture.surface, fixture.mesh))
			}
		}
		update_navigation_3d(&serial.world, 1.0/60)
		update_navigation_3d(&parallel.world, 1.0/60, pool)
		navigation_jobs_expect_equal_3d(t, &serial, &parallel)
		if step == 4 {
			state, _ := get_navigation_state_3d(&parallel.world, parallel.agents[4])
			testing.expect(t, state.status == .No_Path && state.path_status == .Insufficient_Clearance,
				"worker batches preserve failed query status without retaining scratch outputs")
		}
	}
	testing.expect(t, serial.world.navigation_3d.meshes[serial.surface].clearance_preparation_count > 0,
		"worker queries share owner-created immutable clearance preparation")
	state, _ := get_navigation_state_3d(&parallel.world, parallel.agents[5])
	testing.expect(t, state.path_status == .Complete && len(state.path) > 1)
}

@(test)
navigation_jobs_controller_motion_matches_serial_fixed_steps :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	pool := jobs.create(2, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	serial := navigation_jobs_fixture_3d(true); defer navigation_jobs_fixture_destroy_3d(&serial)
	parallel := navigation_jobs_fixture_3d(true); defer navigation_jobs_fixture_destroy_3d(&parallel)
	for _ in 0..<12 {
		update_navigation_3d(&serial.world, 1.0/60)
		update_navigation_3d(&parallel.world, 1.0/60, pool)
		navigation_jobs_expect_equal_3d(t, &serial, &parallel)
		physics_3d_update(&serial.world, 1.0/60); physics_3d_update(&parallel.world, 1.0/60)
	}
	state, _ := get_navigation_state_3d(&parallel.world, parallel.agents[0])
	testing.expect(t, state.status == .Moving && navigation.length_3d(state.desired_velocity) > 0,
		"the test exercises main-thread controller movement after worker paths finish")
}

@(test)
navigation_jobs_leave_no_work_after_return_or_world_replacement :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	pool := jobs.create(2, 1); if !testing.expect(t, pool != nil) {return}
	fixture := navigation_jobs_fixture_3d()
	update_navigation_3d(&fixture.world, 1.0/60, pool)
	generation := fixture.world.generation
	// Destroy every borrowed mesh/preparation immediately after the barrier.
	navigation_jobs_fixture_destroy_3d(&fixture)
	fixture = navigation_jobs_fixture_3d()
	testing.expect(t, fixture.world.generation != generation)
	update_navigation_3d(&fixture.world, 1.0/60, pool)
	for entity in fixture.agents[1:] {assert(stop_navigation_3d(&fixture.world, entity))}
	assert(set_navigation_target_3d(&fixture.world, fixture.agents[0], {10,0,2}))
	update_navigation_3d(&fixture.world, 1.0/60, pool)
	state, _ := get_navigation_state_3d(&fixture.world, fixture.agents[0])
	testing.expect(t, state.path_status == .Complete, "a small batch uses the serial path with an available pool")
	// The World retains no pool pointer and remains usable after pool teardown.
	jobs.destroy(pool)
	assert(set_navigation_target_3d(&fixture.world, fixture.agents[0], {10,0,3}))
	update_navigation_3d(&fixture.world, 1.0/60)
	state, _ = get_navigation_state_3d(&fixture.world, fixture.agents[0])
	testing.expect(t, state.path_status == .Complete)
	navigation_jobs_fixture_destroy_3d(&fixture)
}
