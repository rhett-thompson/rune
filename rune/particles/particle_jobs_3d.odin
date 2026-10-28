package particles

import "core:math"
import "rune:jobs"

Particle_Parallel_Min_Count_3D :: 131072
Update_3D_Range_Size :: 1024
Update_3D_Batch :: struct {live: []Particle3D, dt: f32}

// Each original particle advances exactly once. Expired particles retain their
// old motion, as in the serial swap/pop loop; compaction happens after the join.
update_3d_range_job :: proc(index: int, data: rawptr) {
	batch := (^Update_3D_Batch)(data)
	first := index*Update_3D_Range_Size
	last := min(first+Update_3D_Range_Size, len(batch.live))
	for &particle in batch.live[first:last] {
		particle.age += batch.dt
		if particle.age >= particle.lifetime {continue}
		particle.position += particle.velocity*batch.dt + particle.gravity*(0.5*batch.dt*batch.dt)
		particle.velocity += particle.gravity*batch.dt
	}
}

// Use only after every live particle has advanced. The returned prefix matches
// the original serial swap/pop ordering; storage beyond it is unspecified.
compact_3d_slice :: proc(live: []Particle3D) -> int {
	count := len(live)
	i := 0
	for i < count {
		if live[i].age >= live[i].lifetime {count -= 1; live[i] = live[count]; continue}
		i += 1
	}
	return count
}

// Exclusively borrows the live prefix through a synchronous barrier. Workers
// integrate disjoint ranges without allocations; the caller compacts afterward.
update_3d_slice :: proc(live: []Particle3D, dt: f32, pool: ^jobs.Pool = nil) -> int {
	if dt <= 0 || math.is_nan(dt) || math.is_inf(dt) {return len(live)}
	if pool == nil || len(live) < Particle_Parallel_Min_Count_3D {
		// Keep the original single-pass serial cost for ordinary small pools.
		count := len(live)
		i := 0
		for i < count {
			particle := &live[i]
			particle.age += dt
			if particle.age >= particle.lifetime {count -= 1; live[i] = live[count]; continue}
			particle.position += particle.velocity*dt + particle.gravity*(0.5*dt*dt)
			particle.velocity += particle.gravity*dt
			i += 1
		}
		return count
	}
	batch := Update_3D_Batch{live, dt}
	ranges := (len(live)+Update_3D_Range_Size-1)/Update_3D_Range_Size
	jobs.parallel_for(pool, ranges, update_3d_range_job, &batch)
	return compact_3d_slice(live)
}
