package ecs

import "rune:jobs"
import "rune:particles"

@(private)
Particle_Emitter_Update_2D :: struct {entity: Entity, state: particles.State}

// World maps, enabled hierarchy and composed transforms remain owner-only.
// Temporarily moved State headers own disjoint buffers until the join; no map
// can be read/written concurrently and no worker retains a World reference.
@(private)
update_particle_jobs_2d :: proc(world: ^World, dt: f32, pool: ^jobs.Pool) {
	updates := make([]Particle_Emitter_Update_2D, len(world.particle_emitters_2d), context.temp_allocator)
	work := make([]particles.Update_2D_Work, len(updates), context.temp_allocator)
	count := 0
	for entity, settings in world.particle_emitters_2d {
		if !is_enabled(world, entity) {continue}
		position, rotation, scale := particle_emitter_pose_2d(world, entity)
		updates[count] = {entity, world.particle_states_2d[entity]}
		work[count] = {state=&updates[count].state, settings=settings, origin=position, rotation=rotation, scale=scale}
		count += 1
	}
	particles.update_many_2d(work[:count], dt, pool)
	for update in updates[:count] {world.particle_states_2d[update.entity] = update.state}
}
