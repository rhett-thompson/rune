package particles

import "core:math"
import "rune:jobs"

// Conservative common cutoff from the headless worker benchmark on Windows
// and Linux/WSL. Smaller batches keep the direct serial update path.
Particle_Parallel_Min_Work_2D :: 131072

// Every State is exclusively writable and must occur only once in the batch.
// Settings and poses are snapshots; texture strings are never accessed by jobs.
Update_2D_Work :: struct {
	state: ^State,
	settings: Emitter2D,
	origin: [2]f32,
	rotation, scale: f32,
}

Update_2D_Batch :: struct {work: []Update_2D_Work, dt: f32}

// Raw callback for owner-prepared, exclusively borrowed State storage.
update_2d_job :: proc(index: int, data: rawptr) {
	batch := (^Update_2D_Batch)(data)
	item := &batch.work[index]
	if item.state != nil {update_prepared(item.state, item.settings, batch.dt, item.origin, item.rotation, item.scale)}
}

// Synchronous, whole-emitter jobs preserve each emitter's serial random stream,
// distributed births and swap/pop order. Reserve on the caller before workers
// borrow State headers/buffers, including States with non-thread-safe allocators.
update_many_2d :: proc(work: []Update_2D_Work, dt: f32, pool: ^jobs.Pool = nil) {
	if dt <= 0 || math.is_nan(dt) || math.is_inf(dt) {return}
	if pool == nil || len(work) < 2 {
		for item in work {if item.state != nil {update(item.state, item.settings, dt, item.origin, item.rotation, item.scale)}}
		return
	}
	estimated_work := 0
	active_emitters := 0
	for item in work {
		if item.state == nil || !valid(item.settings) {continue}
		item_work := len(item.state.particles)
		if item.settings.emitting && item.settings.rate > 0 {
			item_work += int(min(f64(item.settings.max_particles), math.floor(item.state.credit + f64(item.settings.rate)*f64(dt))))
		}
		estimated_work += item_work
		if item_work > 0 {active_emitters += 1}
	}
	if active_emitters < 2 || estimated_work < Particle_Parallel_Min_Work_2D {
		for item in work {if item.state != nil {update(item.state, item.settings, dt, item.origin, item.rotation, item.scale)}}
		return
	}
	for item in work {if item.state != nil {prepare_update(item.state, item.settings, dt)}}
	batch := Update_2D_Batch{work, dt}
	jobs.parallel_for(pool, len(work), update_2d_job, &batch)
}
