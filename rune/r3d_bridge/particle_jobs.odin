package r3d_bridge

import "core:math"
import "core:slice"
import "rune:jobs"
import "rune:particles"
import rl "vendor:raylib"

Particle_Billboard_Chunk_Size :: 2048
// Conservative common Windows/Linux cutoff from particle_worker_benchmark.
Particle_Billboard_Parallel_Min :: 16384

// Distinct destinations; source slices remain read-only through the barrier.
// Finish growing the descriptor and destination arrays before dispatch.
Particle_Billboard_Work :: struct {
	state: ^Particle_Billboard_Batch,
	batch: Particle3D_Batch,
	camera: rl.Camera3D,
	first_chunk, chunk_count: int,
	ready: bool,
}
Particle_Billboard_Prepare_Batch :: struct {work: []Particle_Billboard_Work}
Particle_Billboard_Prepare_Stats :: struct {particles, instances, chunks, job_batches: int}

particle_billboard_instance :: proc(p:particles.Particle3D,camera:rl.Camera3D) -> (Particle_Billboard_Instance,bool) {
	if p.lifetime<=0 {return {},false}
	for value in ([7]f32{p.position[0],p.position[1],p.position[2],p.age,p.lifetime,p.start_size,p.end_size}) {
		if math.is_nan(value) || math.is_inf(value) {return {},false}
	}
	size,color:=particles.appearance_3d(p)
	if size<=0 || color[3]==0 {return {},false}
	delta:=p.position-camera.position
	forward:=camera.target-camera.position
	return {position=rl.Vector3(p.position),scale={size,size,size},color=rl.Color(color),
		depth=delta[0]*forward[0]+delta[1]*forward[1]+delta[2]*forward[2]},true
}

// Owner-only reservation: worker phases never grow retained allocator storage.
prepare_particle_billboard_storage :: proc(work:[]Particle_Billboard_Work) -> (chunks,ready_batches:int) {
	for &item in work {
		item.ready=false;item.first_chunk=chunks;item.chunk_count=0
		if item.state==nil {continue}
		state:=item.state
		clear(&state.instances);clear(&state.positions);clear(&state.scales);clear(&state.colors)
		count:=len(item.batch.particles)
		if count==0 {continue}
		if reserve(&state.instances,count)!=nil || reserve(&state.positions,count)!=nil ||
		   reserve(&state.scales,count)!=nil || reserve(&state.colors,count)!=nil {continue}
		resize(&state.instances,count);resize(&state.positions,count);resize(&state.scales,count);resize(&state.colors,count)
		item.ready=true;item.chunk_count=(count+Particle_Billboard_Chunk_Size-1)/Particle_Billboard_Chunk_Size
		chunks+=item.chunk_count;ready_batches+=1
	}
	return
}

particle_billboard_range_job :: proc(index:int,data:rawptr) {
	batch:=(^Particle_Billboard_Prepare_Batch)(data)
	// Descriptor ranges are monotonic, including empty/failed destinations.
	low,high:=0,len(batch.work)
	for low<high {
		middle:=(low+high)/2
		item:=&batch.work[middle]
		if index>=item.first_chunk+item.chunk_count {low=middle+1} else {high=middle}
	}
	item:=&batch.work[low]
	start:=(index-item.first_chunk)*Particle_Billboard_Chunk_Size
	end:=min(start+Particle_Billboard_Chunk_Size,len(item.batch.particles))
	for i in start..<end {
		instance,ok:=particle_billboard_instance(item.batch.particles[i],item.camera)
		item.state.instances[i]=instance if ok else Particle_Billboard_Instance{}
	}
}

particle_billboard_finalize_job :: proc(index:int,data:rawptr) {
	batch:=(^Particle_Billboard_Prepare_Batch)(data)
	item:=&batch.work[index]
	if !item.ready {return}
	state:=item.state
	count:=0
	// Preserve input order before the existing alpha sort, including depth ties.
	for instance,index in state.instances {
		if instance.scale.x<=0 {continue}
		if count!=index {state.instances[count]=instance}
		count+=1
	}
	resize(&state.instances,count)
	if item.batch.blend==.Alpha {
		slice.sort_by(state.instances[:],proc(a,b:Particle_Billboard_Instance)->bool {return a.depth>b.depth})
	}
	resize(&state.positions,count);resize(&state.scales,count);resize(&state.colors,count)
	for instance,i in state.instances {
		state.positions[i]=instance.position;state.scales[i]=instance.scale;state.colors[i]=instance.color
	}
}

prepare_particle_billboard_work :: proc(work:[]Particle_Billboard_Work,pool:^jobs.Pool=nil) -> Particle_Billboard_Prepare_Stats {
	stats:Particle_Billboard_Prepare_Stats
	for item in work {if item.state!=nil {stats.particles+=len(item.batch.particles)}}
	if pool==nil || stats.particles<Particle_Billboard_Parallel_Min {
		for item in work {
			if item.state==nil {continue}
			prepare_particle_billboards_serial(item.state,item.batch,item.camera)
			stats.instances+=len(item.state.instances)
		}
		return stats
	}
	chunks,ready_batches:=prepare_particle_billboard_storage(work)
	stats.chunks=chunks
	batch:=Particle_Billboard_Prepare_Batch{work}
	if chunks>1 {jobs.parallel_for(pool,chunks,particle_billboard_range_job,&batch);stats.job_batches+=1}
	else if chunks==1 {particle_billboard_range_job(0,&batch)}
	if ready_batches>1 {jobs.parallel_for(pool,len(work),particle_billboard_finalize_job,&batch);stats.job_batches+=1}
	else {for i in 0..<len(work) {particle_billboard_finalize_job(i,&batch)}}
	for item in work {if item.state!=nil {stats.instances+=len(item.state.instances)}}
	return stats
}

// Compatible direct CPU entry point. Graphics submission uses the same helper
// across all billboard batches before touching native instance buffers.
prepare_particle_billboards :: proc(state:^Particle_Billboard_Batch,batch:Particle3D_Batch,camera:rl.Camera3D,pool:^jobs.Pool=nil) {
	work:=[1]Particle_Billboard_Work{{state=state,batch=batch,camera=camera}}
	prepare_particle_billboard_work(work[:],pool)
}
