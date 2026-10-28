package main

import "core:math"
import "core:mem"
import "core:sync"
import "rune:jobs"
import "rune:particles"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

Billboard_Count :: max(16384,bridge.Particle_Billboard_Parallel_Min)

particle_fixture :: proc(count:int,offset:f32=0,invalid:bool=true) -> []particles.Particle3D {
	live:=make([]particles.Particle3D,count)
	for &p,index in live {
		p={position={f32(index%128)*0.07-4.4+offset,f32((index/128)%32)*0.1-1.6,f32(index%8)*0.3-1},
			age=f32(index%7)*0.1,lifetime=2,start_size=0.12,end_size=0.04,
			start_color={u8(40+index%180),u8(200-index%140),u8(60+index%180),100},end_color={230,50,170,30}}
		if invalid {
			switch index%37 {
			case 0: p.start_color[3]=0;p.end_color[3]=0
			case 1: p.start_size=0;p.end_size=0
			case 2: p.lifetime=0
			case 3: p.position[0]=math.nan_f32()
			case 4: p.age=math.inf_f32(1)
			case 5: p.end_size=math.inf_f32(-1)
			}
		}
	}
	return live
}

release_prepared :: proc(state:^bridge.Particle_Billboard_Batch) {
	delete(state.instances);delete(state.positions);delete(state.scales);delete(state.colors);state^={}
}

compare_prepared :: proc(a,b:^bridge.Particle_Billboard_Batch) {
	assert(len(a.instances)==len(b.instances) && len(a.positions)==len(b.positions) && len(a.scales)==len(b.scales) && len(a.colors)==len(b.colors))
	for item,index in a.instances {assert(item==b.instances[index],"classification, depth ties, compaction and sort match scalar order")}
	for item,index in a.positions {assert(item==b.positions[index] && a.scales[index]==b.scales[index] && a.colors[index]==b.colors[index],"packed instance streams match exactly")}
}

Preparation_Busy :: struct {work:[]bridge.Particle_Billboard_Work}
preparation_busy :: proc(pool:^jobs.Pool,data:rawptr) {
	batch:=(^Preparation_Busy)(data)
	stats:=bridge.prepare_particle_billboard_work(batch.work,pool)
	assert(stats.job_batches==2)
}

Preparation_Background :: struct {work:[]bridge.Particle_Billboard_Work,chunks,thread_id:int,allocator:mem.Allocator}
preparation_background :: proc(data:rawptr) {
	work:=(^Preparation_Background)(data);work.thread_id=sync.current_thread_id()
	if work.allocator.procedure!=nil {context.allocator=work.allocator}
	batch:=bridge.Particle_Billboard_Prepare_Batch{work.work}
	for index in 0..<work.chunks {bridge.particle_billboard_range_job(index,&batch)}
	for index in 0..<len(work.work) {bridge.particle_billboard_finalize_job(index,&batch)}
}

Preparation_Allocator :: struct {backing:mem.Allocator,owner,remaining_growth,foreign_calls:int}
preparation_allocator :: proc(data:rawptr,mode:mem.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,mem.Allocator_Error) {
	guard:=(^Preparation_Allocator)(data)
	if sync.current_thread_id()!=guard.owner {sync.atomic_add(&guard.foreign_calls,1);return nil,.Out_Of_Memory}
	if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
		if guard.remaining_growth==0 {return nil,.Out_Of_Memory}
		if guard.remaining_growth>0 {guard.remaining_growth-=1}
	}
	return guard.backing.procedure(guard.backing.data,mode,size,alignment,old_memory,old_size,loc)
}

validate_reservation_failure :: proc(pool:^jobs.Pool,live:[]particles.Particle3D) {
	for allowed in ([3]int{0,2,3}) {
		guard:=Preparation_Allocator{backing=context.allocator,owner=sync.current_thread_id(),remaining_growth=allowed}
		{
			context.allocator={preparation_allocator,&guard}
			state:bridge.Particle_Billboard_Batch;defer release_prepared(&state)
			work:=[1]bridge.Particle_Billboard_Work{{state=&state,batch={particles=live,shape=.Billboard,blend=.Alpha},camera={position={0,0,10}}}}
			failed:=bridge.prepare_particle_billboard_work(work[:],pool)
			assert(!work[0].ready && failed.instances==0 && failed.job_batches==0 && guard.foreign_calls==0,"failed owner reservations exclude the entire destination from jobs")
			assert(len(state.instances)==0 && len(state.positions)==0 && len(state.scales)==0 && len(state.colors)==0,"partial reservation failure publishes no stale streams")
			guard.remaining_growth=-1
			recovered:=bridge.prepare_particle_billboard_work(work[:],pool)
			assert(work[0].ready && recovered.instances>0 && recovered.job_batches==1 && guard.foreign_calls==0,"a later owner reservation recovers a failed destination")
			chunks,_:=bridge.prepare_particle_billboard_storage(work[:])
			background:=Preparation_Background{work=work[:],chunks=chunks,allocator=context.allocator};group:jobs.Group
			assert(jobs.submit(pool,&group,preparation_background,&background));jobs.wait(&group)
			assert(background.thread_id!=guard.owner && guard.foreign_calls==0,"worker callbacks use neither retained nor contextual owner allocators")
		}
	}
}

validate_preparation :: proc(pool:^jobs.Pool) {
	tracker:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
	{
		context.allocator=mem.tracking_allocator(&tracker)
		live:=particle_fixture(Billboard_Count);defer delete(live)
		original:=hash_bytes(mem.slice_to_bytes(live))
		serial,parallel:[3]bridge.Particle_Billboard_Batch
		defer {for &state in serial {release_prepared(&state)};for &state in parallel {release_prepared(&state)}}
		work:[3]bridge.Particle_Billboard_Work
		camera:=rl.Camera3D{position={0,0,10},target={0,0,0},up={0,1,0},fovy=45}
		for &item,index in work {item={state=&parallel[index],batch={particles=live[:Billboard_Count-index*257],shape=.Billboard,blend=.Alpha},camera=camera}}
		for turn in 0..<3 {
			if turn==1 {camera.position={10,2,0}}
			if turn==2 {camera.position={-5,1,-8}}
			for &item,index in work {
				item.camera=camera;item.batch.blend=.Additive if turn==2 else .Alpha
				bridge.prepare_particle_billboards(&serial[index],item.batch,camera)
			}
			stats:=bridge.prepare_particle_billboard_work(work[:],pool)
			assert(stats.job_batches==2 && stats.chunks>1 && stats.instances>0)
			for &state,index in serial {compare_prepared(&state,&parallel[index])}
			assert(hash_bytes(mem.slice_to_bytes(live))==original,"preparation never mutates simulation, including invalid inputs")
		}
		before:=tracker.total_allocation_count
		for _ in 0..<5 {bridge.prepare_particle_billboard_work(work[:],pool)}
		assert(tracker.total_allocation_count==before,"warm classification, compaction, sorting and packing make no owner allocation calls")
		chunks,_:=bridge.prepare_particle_billboard_storage(work[:])
		background:=Preparation_Background{work=work[:],chunks=chunks};group:jobs.Group
		assert(jobs.submit(pool,&group,preparation_background,&background));jobs.wait(&group)
		assert(background.thread_id!=sync.current_thread_id() && tracker.total_allocation_count==before,"Odin preparation phases execute on a different thread without growing owner storage")
		for &state,index in serial {compare_prepared(&state,&parallel[index])}
		for full in ([2]bool{false,true}) {
			busy:=Preparation_Busy{work[:]};with_busy_pool(full,preparation_busy,&busy)
			for &state,index in serial {compare_prepared(&state,&parallel[index])}
		}
		for &item,index in work {
			item.batch.particles=nil
			bridge.prepare_particle_billboards(&serial[index],item.batch,camera)
		}
		empty:=bridge.prepare_particle_billboard_work(work[:],pool)
		assert(empty.instances==0 && empty.job_batches==0)
		for &state,index in serial {compare_prepared(&state,&parallel[index]);assert(len(state.instances)==0)}
		for &item in work {item.batch.particles=live[:512]}
		small:=bridge.prepare_particle_billboard_work(work[:],pool)
		assert(small.job_batches==0,"small effects retain scalar preparation")
		for &item,index in work {bridge.prepare_particle_billboards(&serial[index],item.batch,camera);compare_prepared(&serial[index],&parallel[index])}
		validate_reservation_failure(pool,live)
	}
	assert(tracker.current_memory_allocated==0 && len(tracker.bad_free_array)==0,"prepared streams retain and free their owner allocator")
}
