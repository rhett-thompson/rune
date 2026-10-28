package particles

import "core:mem"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:time"
import "rune:jobs"

Particle_Test_Allocator :: struct {
	backing: mem.Allocator,
	owner: int,
	calls, foreign_calls: int,
	fail: bool,
}

particle_test_allocator :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	guard := (^Particle_Test_Allocator)(data)
	sync.atomic_add(&guard.calls, 1)
	if os.get_current_thread_id() != guard.owner {
		sync.atomic_add(&guard.foreign_calls, 1)
		return nil, .Out_Of_Memory
	}
	if guard.fail && mode != .Free {return nil, .Out_Of_Memory}
	return guard.backing.procedure(guard.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

expect_particle_state_equal :: proc(t: ^testing.T, a, b: ^State) {
	testing.expect(t, a.credit == b.credit && a.random == b.random && a.initialized == b.initialized,
		"credit and random stream preserve serial birth ordering")
	testing.expect(t, slice.equal(a.particles[:], b.particles[:]), "the complete live prefix preserves serial swap/pop ordering and birth settings")
}

@(test)
particle_updates_reject_invalid_inputs_without_simulation_or_allocation :: proc(t: ^testing.T) {
	guard := Particle_Test_Allocator{backing=context.allocator, owner=os.get_current_thread_id()}
	context.allocator = {particle_test_allocator, &guard}
	state: State; defer destroy(&state)
	settings := defaults(); settings.max_particles = 16
	emit(&state, settings, 8, {3,5})
	before := state
	values := make([]Particle2D, len(state.particles)); defer delete(values)
	copy(values, state.particles[:])
	for dt in ([4]f32{0,-1,transmute(f32)u32(0x7fc00000),transmute(f32)u32(0x7f800000)}) {
		calls := guard.calls
		testing.expect(t, !prepare_update(&state, settings, dt))
		update(&state, settings, dt, {}); update_prepared(&state, settings, dt, {})
		testing.expect(t, guard.calls == calls && state.credit == before.credit && state.random == before.random &&
			state.initialized == before.initialized && slice.equal(state.particles[:], values))
	}
	for index in 0..<3 {
		invalid := settings
		if index == 0 {invalid.max_particles = 0}
		if index == 1 {invalid.lifetime[1] = -1}
		if index == 2 {invalid.rate = transmute(f32)u32(0x7fc00000)}
		calls := guard.calls
		testing.expect(t, !prepare_update(&state, invalid, 0.016))
		update(&state, invalid, 0.016, {}); update_prepared(&state, invalid, 0.016, {})
		testing.expect(t, guard.calls == calls && state.credit == before.credit && state.random == before.random &&
			state.initialized == before.initialized && slice.equal(state.particles[:], values))
	}
}

@(test)
particle_emitter_jobs_preserve_births_deaths_settings_and_owner_allocator :: proc(t: ^testing.T) {
	pool := jobs.create(3, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	guard := Particle_Test_Allocator{backing=context.allocator, owner=os.get_current_thread_id()}
	context.allocator = {particle_test_allocator, &guard}
	serial, parallel: [8]State
	defer {for &state in serial {destroy(&state)}; for &state in parallel {destroy(&state)}}
	work: [8]Update_2D_Work
	initial_count := max(768, (Particle_Parallel_Min_Work_2D+len(work)-1)/len(work))
	initial_capacity := max(1024, initial_count*4/3)
	for &item, index in work {
		settings := defaults(); settings.max_particles = i32(initial_capacity); settings.seed = u32(index+71)
		settings.rate = 50000; settings.lifetime = {0.025, 0.15}; settings.gravity = {1, 7}
		item = {&parallel[index], settings, {f32(index)*10,-3}, f32(index)*17, -1.5}
		for state in ([2]^State{&serial[index], &parallel[index]}) {emit(state, settings, initial_count, item.origin, item.rotation, item.scale)}
	}
	for step in 0..<24 {
		for &item, index in work {
			if step == 3 {item.settings.emitting = index%2 == 0}
			if step == 6 {item.settings.max_particles = i32(2*initial_capacity); item.settings.rate = 7000; item.settings.seed = 999}
			if step == 8 {item.settings.emitting = true; item.settings.lifetime = {0.1,0.3}; item.settings.start_color = {7,11,19,251}}
			if step == 12 {clear(&serial[index]); clear(&parallel[index])}
			if step == 15 {item.settings.max_particles = 512; item.settings.gravity = {-3,-6}}
			item.origin += {0.5, -0.25}; item.rotation += 3
			update(&serial[index], item.settings, 0.021, item.origin, item.rotation, item.scale)
		}
		update_many_2d(work[:], 0.021, pool)
		for index in 0..<len(work) {expect_particle_state_equal(t, &serial[index], &parallel[index])}
	}
	testing.expect(t, guard.foreign_calls == 0, "workers never invoke the State's retained owner allocator")
}

Prepared_Particle_Probe :: struct {batch: Update_2D_Batch, allocator: mem.Allocator, thread_id: int}
Prepared_Particle_Probe_3D :: struct {batch: Update_3D_Batch, allocator: mem.Allocator, thread_id: int}

prepared_particle_probe_3d :: proc(data: rawptr) {
	probe := (^Prepared_Particle_Probe_3D)(data)
	probe.thread_id = os.get_current_thread_id()
	context.allocator = probe.allocator
	context.temp_allocator = probe.allocator
	for index in 0..<(len(probe.batch.live)+Update_3D_Range_Size-1)/Update_3D_Range_Size {update_3d_range_job(index, &probe.batch)}
}

prepared_particle_probe :: proc(data: rawptr) {
	probe := (^Prepared_Particle_Probe)(data)
	probe.thread_id = os.get_current_thread_id()
	// Deliberately catch even accidental fresh allocations in the callback.
	context.allocator = probe.allocator
	context.temp_allocator = probe.allocator
	for index in 0..<len(probe.batch.work) {update_2d_job(index, &probe.batch)}
}

@(test)
prepared_particle_births_on_worker_use_only_owner_reserved_storage :: proc(t: ^testing.T) {
	pool := jobs.create(1, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	guard := Particle_Test_Allocator{backing=context.allocator, owner=os.get_current_thread_id()}
	allocator := mem.Allocator{particle_test_allocator, &guard}
	context.allocator = allocator
	serial, parallel: State
	defer destroy(&serial); defer destroy(&parallel)
	settings := defaults(); settings.max_particles = 1024; settings.rate = 50000
	testing.expect(t, prepare_update(&parallel, settings, 0.02))
	testing.expect(t, !parallel.initialized && parallel.random == 0 && parallel.credit == 0 && len(parallel.particles) == 0,
		"owner reservation has no simulation side effects")
	update(&serial, settings, 0.02, {3,7}, 23, -2)
	work := [1]Update_2D_Work{{&parallel,settings,{3,7},23,-2}}
	probe := Prepared_Particle_Probe{batch={work[:],0.02},allocator=allocator}
	before := guard.calls
	group: jobs.Group
	if !testing.expect(t, jobs.submit(pool, &group, prepared_particle_probe, &probe)) {return}
	jobs.wait(&group)
	testing.expect(t, probe.thread_id != guard.owner && guard.calls == before && guard.foreign_calls == 0,
		"real worker births use reserved storage without invoking any allocator")
	expect_particle_state_equal(t, &serial, &parallel)
	testing.expect(t, len(parallel.particles) > 900, "the worker exercises seeded emission and append without allocation")
}

@(test)
particle_3d_worker_ranges_do_not_allocate_or_compact_borrowed_storage :: proc(t: ^testing.T) {
	pool := jobs.create(1, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	guard := Particle_Test_Allocator{backing=context.allocator, owner=os.get_current_thread_id()}
	allocator := mem.Allocator{particle_test_allocator, &guard}
	context.allocator = allocator
	live := make([]Particle3D, 8193); defer delete(live)
	reference := make([]Particle3D, len(live)); defer delete(reference)
	for &particle, index in live {particle = particle_job_test_3d(index)}
	copy(reference, live)
	reference_count := update_3d_slice(reference, 0.1)
	probe := Prepared_Particle_Probe_3D{batch={live,0.1},allocator=allocator}
	before := guard.calls
	group: jobs.Group
	if !testing.expect(t, jobs.submit(pool, &group, prepared_particle_probe_3d, &probe)) {return}
	jobs.wait(&group)
	testing.expect(t, probe.thread_id != guard.owner && guard.calls == before && guard.foreign_calls == 0,
		"real worker ranges never invoke an allocator")
	count := compact_3d_slice(live)
	testing.expect(t, count == reference_count && slice.equal(live[:count], reference[:reference_count]),
		"only the owner compacts after the range barrier, preserving the exact live prefix")
}

@(test)
prepared_particle_updates_never_retry_failed_reservations_on_worker :: proc(t: ^testing.T) {
	pool := jobs.create(1, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	guard := Particle_Test_Allocator{backing=context.allocator, owner=os.get_current_thread_id()}
	allocator := mem.Allocator{particle_test_allocator, &guard}
	context.allocator = allocator
	serial, parallel: [2]State
	defer {guard.fail = false; for &state in serial {destroy(&state)}; for &state in parallel {destroy(&state)}}
	settings := defaults(); settings.max_particles = 8; settings.rate = 9000
	for state in ([2]^State{&serial[1], &parallel[1]}) {emit(state, settings, 8, {})}
	settings.max_particles = 4096
	guard.fail = true
	work: [2]Update_2D_Work
	for &item, index in work {
		item = {state=&parallel[index], settings=settings, scale=1}
		testing.expect(t, !prepare_update(item.state, settings, 0.2), "owner preparation reports a failed allocation/resize")
		update(&serial[index], settings, 0.2, {})
	}
	before := guard.calls
	probe := Prepared_Particle_Probe{batch={work[:],0.2}, allocator=allocator}
	group: jobs.Group
	if !testing.expect(t, jobs.submit(pool, &group, prepared_particle_probe, &probe)) {return}
	jobs.wait(&group)
	testing.expect(t, probe.thread_id != guard.owner && guard.calls == before && guard.foreign_calls == 0,
		"a real worker performs no allocation attempts after failed owner preparation")
	for index in 0..<len(work) {expect_particle_state_equal(t, &serial[index], &parallel[index])}
	testing.expect(t, parallel[0].initialized && parallel[0].random == settings.seed,
		"a failed first birth still initializes the seed before allocation, preserving legacy behavior")
}

Particle_Queue_Block :: struct {started, release: sync.Sema, timed_out: bool}
particle_queue_block :: proc(data: rawptr) {
	block := (^Particle_Queue_Block)(data)
	sync.sema_post(&block.started)
	block.timed_out = !sync.sema_wait_with_timeout(&block.release, 2*time.Second)
}

Nested_Particle_Update :: struct {work: []Update_2D_Work, pool: ^jobs.Pool, live: []Particle3D, count: int}
nested_particle_update :: proc(data: rawptr) {
	request := (^Nested_Particle_Update)(data)
	update_many_2d(request.work, 0.016, request.pool)
	request.count = update_3d_slice(request.live, 0.016, request.pool)
}

@(test)
particle_updates_finish_with_occupied_full_or_free_queue_and_nested_calls :: proc(t: ^testing.T) {
	pool := jobs.create(1, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	serial, parallel: [2]State
	defer {for &state in serial {destroy(&state)}; for &state in parallel {destroy(&state)}}
	work: [2]Update_2D_Work
	initial_count := max(4096, (Particle_Parallel_Min_Work_2D+len(work)-1)/len(work))
	settings := defaults(); settings.max_particles = i32(initial_count); settings.lifetime = {2,3}; settings.rate = 50
	for &item, index in work {
		item = {state=&parallel[index], settings=settings, scale=1}
		for state in ([2]^State{&serial[index], &parallel[index]}) {emit(state, settings, initial_count, {})}
	}
	live_storage := make([]Particle3D, 2*Particle_Parallel_Min_Count_3D); defer delete(live_storage)
	reference_storage := make([]Particle3D, len(live_storage)); defer delete(reference_storage)
	live, reference := live_storage, reference_storage
	for &particle, index in live {particle = particle_job_test_3d(index)}
	copy(reference, live)
	for full_queue in ([2]bool{false,true}) {
		block: Particle_Queue_Block; group: jobs.Group; queued: int
		if !testing.expect(t, jobs.submit(pool, &group, particle_queue_block, &block)) {return}
		started := sync.sema_wait_with_timeout(&block.started, 2*time.Second)
		if !testing.expect(t, started) {sync.sema_post(&block.release); jobs.wait(&group); return}
		if full_queue {testing.expect(t, jobs.submit(pool, &group, proc(data: rawptr) {(^int)(data)^ += 1}, &queued))}
		update_many_2d(work[:], 0.016, pool)
		for index in 0..<len(work) {update(&serial[index], settings, 0.016, {}); expect_particle_state_equal(t, &serial[index], &parallel[index])}
		count := update_3d_slice(live, 0.016, pool)
		reference_count := update_3d_slice(reference, 0.016)
		testing.expect(t, count == reference_count && slice.equal(live[:count], reference[:reference_count]))
		live = live[:count]; reference = reference[:reference_count]
		testing.expect(t, !jobs.is_complete(&group), "synchronous batches return while unrelated workers remain blocked")
		sync.sema_post(&block.release); jobs.wait(&group)
		testing.expect(t, !block.timed_out && queued == int(full_queue), "a full or available queue does not stall caller fallback")
	}
	request := Nested_Particle_Update{work=work[:], pool=pool, live=live}
	group: jobs.Group
	if !testing.expect(t, jobs.submit(pool, &group, nested_particle_update, &request)) {return}
	jobs.wait(&group)
	for index in 0..<len(work) {update(&serial[index], settings, 0.016, {}); expect_particle_state_equal(t, &serial[index], &parallel[index])}
	reference_count := update_3d_slice(reference, 0.016)
	testing.expect(t, request.count == reference_count && slice.equal(live[:request.count], reference[:reference_count]), "nested worker batches execute inline and retain deterministic output")
}
