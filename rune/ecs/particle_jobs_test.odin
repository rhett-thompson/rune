package ecs

import "core:mem"
import "core:slice"
import "core:testing"
import "rune:jobs"
import "rune:particles"

Particle_Jobs_Fixture_2D :: struct {
	world: World,
	registry: Component_Registry,
	parent: Entity,
	emitters: [8]Entity,
}

particle_jobs_fixture_2d :: proc() -> Particle_Jobs_Fixture_2D {
	f := Particle_Jobs_Fixture_2D{world=init(), registry=init_registry()}
	assert(register_builtin_components(&f.registry))
	f.parent = create_entity(&f.world)
	pose := default_transform(); pose.position = {10,-20,0}; pose.rotation = {0,0,27}; pose.scale = {2,-1.5,1}
	assert(add(&f.world, &f.registry, f.parent, pose))
	initial_count := max(1536, (particles.Particle_Parallel_Min_Work_2D+len(f.emitters)-1)/len(f.emitters))
	for &entity, index in f.emitters {
		entity = create_entity(&f.world)
		pose = default_transform(); pose.position = {f32(index)*3,5,0}; pose.rotation[2] = f32(index)*13; pose.scale = {-1,0.5,1}
		assert(add(&f.world, &f.registry, entity, pose) && set_parent(&f.world, entity, f.parent))
		settings := default_particle_emitter_2d(); settings.max_particles = i32(max(2048, initial_count*4/3)); settings.seed = u32(17+index)
		settings.rate = 4000; settings.lifetime = {0.03,0.2}; settings.gravity = {1,7}
		assert(add(&f.world, &f.registry, entity, settings))
		assert(emit_particles_2d(&f.world, entity, initial_count) == initial_count)
	}
	return f
}

destroy_particle_jobs_fixture_2d :: proc(f: ^Particle_Jobs_Fixture_2D) {
	destroy(&f.world); destroy_registry(&f.registry)
}

expect_particle_jobs_fixture_equal_2d :: proc(t: ^testing.T, a, b: ^Particle_Jobs_Fixture_2D) {
	for entity, index in a.emitters {
		x := a.world.particle_states_2d[entity]; y := b.world.particle_states_2d[b.emitters[index]]
		testing.expect(t, x.credit == y.credit && x.random == y.random && x.initialized == y.initialized &&
			slice.equal(x.particles[:], y.particles[:]), "owner pose gathering and worker simulation preserve every live field, RNG and emission credit")
	}
}

@(test)
particle_ecs_jobs_match_hierarchy_activation_settings_bursts_and_cleanup :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	pool := jobs.create(3, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	serial := particle_jobs_fixture_2d(); defer destroy_particle_jobs_fixture_2d(&serial)
	parallel := particle_jobs_fixture_2d(); defer destroy_particle_jobs_fixture_2d(&parallel)
	for step in 0..<24 {
		for f in ([2]^Particle_Jobs_Fixture_2D{&serial,&parallel}) {
			if step == 2 {assert(set_enabled(&f.world, f.emitters[1], false))}
			if step == 3 {assert(set_enabled(&f.world, f.parent, false))}
			if step == 4 {assert(set_enabled(&f.world, f.parent, true))}
			if step == 6 {assert(set_enabled(&f.world, f.emitters[1], true))}
			if step == 7 {
				pose, _ := get_transform(&f.world, f.parent); pose.position += {7,-2,0}; pose.scale = {-3,2,1}; pose.rotation[2] -= 35
				assert(set_transform(&f.world, f.parent, pose))
			}
			if step == 8 || step == 11 || step == 13 {
				for entity in f.emitters {
					settings, _ := get_particle_emitter_2d(&f.world, entity)
					settings.emitting = step != 8
					settings.max_particles = 2*settings.max_particles if step == 8 else settings.max_particles
					if step == 13 {settings.max_particles = 512}
					settings.seed = 909; settings.gravity = {-2,9}; settings.start_color = {9,17,31,223}
					assert(set_particle_emitter_2d(&f.world, entity, settings))
				}
			}
			if step == 10 {
				assert(clear_particles_2d(&f.world, f.emitters[2]))
				assert(emit_particles_2d(&f.world, f.emitters[3], 500) >= 0)
			}
		}
		update_particles_2d(&serial.world, 0.021)
		update_particles_2d(&parallel.world, 0.021, pool)
		expect_particle_jobs_fixture_equal_2d(t, &serial, &parallel)
	}
	// No callback retains either World, its map headers, or borrowed arena data.
	destroy_particle_jobs_fixture_2d(&parallel)
	parallel = particle_jobs_fixture_2d()
	update_particles_2d(&parallel.world, 0.016, pool)
	testing.expect(t, particle_count_2d(&parallel.world, parallel.emitters[0]) > 0)
}

@(test)
particle_ecs_jobs_preserve_small_invalid_and_disabled_updates :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	pool := jobs.create(1, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	serial := particle_jobs_fixture_2d(); defer destroy_particle_jobs_fixture_2d(&serial)
	parallel := particle_jobs_fixture_2d(); defer destroy_particle_jobs_fixture_2d(&parallel)
	for dt in ([4]f32{0,-1,transmute(f32)u32(0x7fc00000),transmute(f32)u32(0x7f800000)}) {
		update_particles_2d(&serial.world, dt); update_particles_2d(&parallel.world, dt, pool)
		expect_particle_jobs_fixture_equal_2d(t, &serial, &parallel)
	}
	for f in ([2]^Particle_Jobs_Fixture_2D{&serial,&parallel}) {
		for entity in f.emitters[1:] {assert(set_enabled(&f.world, entity, false))}
	}
	update_particles_2d(&serial.world, 0.03); update_particles_2d(&parallel.world, 0.03, pool)
	expect_particle_jobs_fixture_equal_2d(t, &serial, &parallel)
}
