package r3d_bridge

import "core:math/linalg"
import "core:math"
import "rune:assets"
import "rune:ecs"
import "rune:jobs"
import "rune:terrain"
import rl "vendor:raylib"
import r3d "r3d:r3d"

Terrain_Detail_Candidate :: struct {
	position: rl.Vector3,
	rotation: rl.Quaternion,
	density_fade_start, density_cutoff: f32,
}

Terrain_Detail_Chunk_Capacity :: 64
Terrain_Detail_Chunk_Span :: f32(8)
Terrain_Detail_Block_Capacity :: 8

Terrain_Detail_Block :: struct {
	offset, count: int,
	bounds: rl.BoundingBox,
	camera: [3]f32,
	camera_reuse_radius: f32,
	ready, outside, full: bool,
}

Terrain_Detail_Chunk :: struct {
	offset, count: int,
	block_offset, block_count: int,
	bounds: rl.BoundingBox,
	visible_count: i32,
	camera: [3]f32,
	camera_reuse_radius: f32,
	ready, dirty, full: bool,
}

Terrain_Detail_Batch :: struct {
	instances: [dynamic]terrain.Detail_Instance,
	// Scattered roots stay immutable until the terrain revision is rebuilt.
	// Cache their world poses independently of the packed visible prefix.
	candidates: []Terrain_Detail_Candidate,
	candidate_transform: ecs.Transform,
	candidates_ready, candidate_align_to_normal, candidate_chunked: bool,
	chunks: []Terrain_Detail_Chunk,
	blocks: []Terrain_Detail_Block,
	packed_indices: []int,
	buffer: r3d.InstanceBuffer,
	visible_count:i32,
	positions: []rl.Vector3,
	rotations: []rl.Quaternion,
	scales: []rl.Vector3,
	colors: []rl.Color,
	view: Terrain_Detail_View,
	view_ready: bool,
	cached_visible_count: i32,
	candidates_tested: int,
	// The intersection of chunk reuse balls, anchored at view.camera.
	camera_reuse_radius: f32,
}

// Only values affecting instance streams belong in this key. Descriptor edits
// rebuild the batch; retaining borrowed descriptor strings here is unnecessary.
Terrain_Detail_View :: struct {
	transform: ecs.Transform,
	camera: [3]f32,
	draw_distance: f32,
	density_distance: [2]f32,
	density_min: f32,
	seed: int,
	grass, align_to_normal, chunked: bool,
}

release_detail_batch :: proc(batch:^Terrain_Detail_Batch) {
	if batch.buffer.capacity>0 {r3d.UnloadInstanceBuffer(batch.buffer)}
	delete(batch.instances)
	delete(batch.candidates)
	delete(batch.chunks)
	delete(batch.blocks)
	delete(batch.packed_indices)
	delete(batch.positions); delete(batch.rotations); delete(batch.scales); delete(batch.colors)
	batch^={}
}

Terrain_Detail_Work :: struct {data:terrain.Data,batches:[]Terrain_Detail_Batch}

scatter_terrain_detail_job :: proc(index:int,pointer:rawptr) {
	work:=(^Terrain_Detail_Work)(pointer)
	work.batches[index].instances=terrain.scatter_details(work.data,work.data.description.details[index])
}

prepare_detail_batches :: proc(cache:^Terrain_Cache,data:terrain.Data,pool:^jobs.Pool=nil,stats:^Render_Stats=nil) -> bool {
	cache.details=make([dynamic]Terrain_Detail_Batch,len(data.description.details))
	work:=Terrain_Detail_Work{data=data,batches=cache.details[:]}
	started:=rl.GetTime()
	jobs.parallel_for(pool,len(cache.details),scatter_terrain_detail_job,&work)
	if stats!=nil {
		stats.terrain_prepare_cpu_ms+=(rl.GetTime()-started)*1000
		if pool!=nil && len(cache.details)>1 {stats.terrain_job_batches+=1}
	}
	started=rl.GetTime()
	defer if stats!=nil {stats.terrain_upload_cpu_ms+=(rl.GetTime()-started)*1000}
	for &batch in cache.details {
		if len(batch.instances)>0 {
			batch.buffer=r3d.LoadInstanceBuffer(i32(len(batch.instances)),{.POSITION,.ROTATION,.SCALE,.COLOR})
			if batch.buffer.capacity!=i32(len(batch.instances)) || batch.buffer.buffers[0]==0 {
				release_detail_batch(&batch); return false
			}
			batch.positions=make([]rl.Vector3,len(batch.instances))
			batch.rotations=make([]rl.Quaternion,len(batch.instances))
			batch.scales=make([]rl.Vector3,len(batch.instances))
			batch.colors=make([]rl.Color,len(batch.instances))
		}
	}
	return true
}

detail_transform :: proc(t:ecs.Transform) -> rl.Matrix {
	return rl.MatrixTranslate(t.position[0],t.position[1],t.position[2])*
		rl.QuaternionToMatrix(rotation_quaternion(t))*rl.MatrixScale(t.scale[0],t.scale[1],t.scale[2])
}

detail_candidates_current :: proc(batch:^Terrain_Detail_Batch,t:ecs.Transform,align_to_normal:bool,chunked:bool=true) -> bool {
	return batch.candidates_ready && len(batch.candidates)==len(batch.instances) &&
		batch.candidate_transform==t && batch.candidate_align_to_normal==align_to_normal && batch.candidate_chunked==chunked
}

make_detail_chunk :: proc(candidates:[]Terrain_Detail_Candidate,offset:int,chunked:bool) -> Terrain_Detail_Chunk {
	chunk:=Terrain_Detail_Chunk{offset=offset,count=1,
		bounds={min=candidates[offset].position,max=candidates[offset].position}}
	end:=min(offset+Terrain_Detail_Chunk_Capacity,len(candidates)) if chunked else len(candidates)
	for index in offset+1..<end {
		bounds:=chunk.bounds
		fits:=true
		for axis in 0..<3 {
			bounds.min[axis]=min(bounds.min[axis],candidates[index].position[axis])
			bounds.max[axis]=max(bounds.max[axis],candidates[index].position[axis])
			fits=fits && bounds.max[axis]-bounds.min[axis]<=Terrain_Detail_Chunk_Span
		}
		// Keep row wraps and separated scatter regions out of a shared broad box.
		// Contiguous source ranges preserve ordering without a spatial sort.
		if chunked && !fits {break}
		chunk.bounds=bounds;chunk.count+=1
	}
	return chunk
}

prepare_detail_candidates :: proc(batch:^Terrain_Detail_Batch,t:ecs.Transform,align_to_normal:bool,chunked:bool=true) {
	if detail_candidates_current(batch,t,align_to_normal,chunked) {return}
	poses_current:=batch.candidates_ready && len(batch.candidates)==len(batch.instances) &&
		batch.candidate_transform==t && batch.candidate_align_to_normal==align_to_normal
	if len(batch.candidates)!=len(batch.instances) {
		delete(batch.candidates)
		batch.candidates=make([]Terrain_Detail_Candidate,len(batch.instances))
	}
	if len(batch.packed_indices)!=len(batch.instances) {
		delete(batch.packed_indices)
		batch.packed_indices=make([]int,len(batch.instances))
	}
	if !poses_current {
		transform:=detail_transform(t)
		terrain_rotation:=rotation_quaternion(t)
		for instance,index in batch.instances {
			rotation:=rl.QuaternionFromAxisAngle({0,1,0},instance.yaw)
			if align_to_normal {
				// Inverse scale keeps the surface normal correct on stretched terrain.
				normal:=linalg.normalize(instance.normal/t.scale)
				rotation=rl.QuaternionFromVector3ToVector3({0,1,0},normal)*rotation
			}
			batch.candidates[index]={position=rl.Vector3Transform(instance.position,transform),rotation=terrain_rotation*rotation}
		}
	}
	chunk_count,offset:=0,0
	for offset<len(batch.candidates) {
		chunk:=make_detail_chunk(batch.candidates,offset,chunked)
		offset+=chunk.count;chunk_count+=1
	}
	if len(batch.chunks)!=chunk_count {
		delete(batch.chunks)
		batch.chunks=make([]Terrain_Detail_Chunk,chunk_count)
	}
	offset=0
	block_count:=0
	for &chunk in batch.chunks {
		chunk=make_detail_chunk(batch.candidates,offset,chunked)
		chunk.block_offset=block_count
		chunk.block_count=(chunk.count+Terrain_Detail_Block_Capacity-1)/Terrain_Detail_Block_Capacity
		block_count+=chunk.block_count
		offset+=chunk.count
	}
	if len(batch.blocks)!=block_count {
		delete(batch.blocks)
		batch.blocks=make([]Terrain_Detail_Block,block_count)
	}
	for chunk in batch.chunks {
		for index in 0..<chunk.block_count {
			start:=chunk.offset+index*Terrain_Detail_Block_Capacity
			count:=min(Terrain_Detail_Block_Capacity,chunk.offset+chunk.count-start)
			bounds:=rl.BoundingBox{min=batch.candidates[start].position,max=batch.candidates[start].position}
			for candidate in batch.candidates[start+1:start+count] {
				for axis in 0..<3 {bounds.min[axis]=min(bounds.min[axis],candidate.position[axis]);bounds.max[axis]=max(bounds.max[axis],candidate.position[axis])}
			}
			batch.blocks[chunk.block_offset+index]={offset=start,count=count,bounds=bounds}
		}
	}
	batch.candidate_transform=t
	batch.candidate_align_to_normal=align_to_normal
	batch.candidate_chunked=chunked
	batch.candidates_ready=true
}

// Root bounds, rather than prototype geometry bounds, match the exact existing
// distance test. These squared extrema classify whole chunks conservatively.
detail_chunk_distances :: proc(bounds:rl.BoundingBox,camera:[3]f32) -> (near_squared,far_squared:f32) {
	// This fixed-size hot path also runs in unoptimized development builds.
	// Keep the original X/Y/Z accumulation order without a dynamic axis loop.
	lx,hx:=bounds.min.x-camera.x,bounds.max.x-camera.x
	ly,hy:=bounds.min.y-camera.y,bounds.max.y-camera.y
	lz,hz:=bounds.min.z-camera.z,bounds.max.z-camera.z
	nx,ny,nz:=max(lx,0)+min(hx,0),max(ly,0)+min(hy,0),max(lz,0)+min(hz,0)
	fx,fy,fz:=max(abs(lx),abs(hx)),max(abs(ly),abs(hy)),max(abs(lz),abs(hz))
	near_squared=(nx*nx+ny*ny)+nz*nz
	far_squared=(fx*fx+fy*fy)+fz*fz
	return
}

detail_block_classification :: proc(block:^Terrain_Detail_Block,camera:[3]f32,draw_distance,cutoff_squared,full_distance,margin:f32,distance_scaled,allow_reuse:bool) -> (outside,full:bool,reuse_radius:f32) {
	if allow_reuse && block.ready {
		movement:=camera-block.camera
		movement_squared:=#force_inline linalg.dot(movement,movement)
		if camera==block.camera || (block.camera_reuse_radius>0 && movement_squared<block.camera_reuse_radius*block.camera_reuse_radius) {
			movement_distance:=#force_inline math.sqrt(movement_squared)
			return block.outside,block.full,max(f32(0),block.camera_reuse_radius-movement_distance)
		}
	}
	block.camera=camera
	block.ready=false;block.outside=false;block.full=false;block.camera_reuse_radius=0
	near_squared,far_squared:=#force_inline detail_chunk_distances(block.bounds,camera)
	if near_squared>=cutoff_squared {
		near_distance:=#force_inline math.sqrt(near_squared)
		block.ready=true;block.outside=true
		block.camera_reuse_radius=max(f32(0),near_distance-draw_distance-margin)
		return true,false,block.camera_reuse_radius
	}
	far_distance:=#force_inline math.sqrt(far_squared)
	if far_squared<cutoff_squared && (!distance_scaled || far_distance<full_distance-margin) {
		block.ready=true;block.full=true
		radius:=full_distance-far_distance if distance_scaled else draw_distance-far_distance
		block.camera_reuse_radius=max(f32(0),radius-margin)
		return false,true,block.camera_reuse_radius
	}
	// Boundary selections and distance-faded grass still use exact root tests.
	return
}

pack_detail_candidate :: proc(batch:^Terrain_Detail_Batch,slot,source:int,scale:f32,t:ecs.Transform,force:bool) -> bool {
	changed:=force || batch.packed_indices[slot]!=source
	if changed {
		batch.positions[slot]=batch.candidates[source].position
		batch.rotations[slot]=batch.candidates[source].rotation
		shade:=u8(batch.instances[source].shade*255)
		batch.colors[slot]={shade,shade,shade,255}
		batch.packed_indices[slot]=source
	}
	world_scale:=t.scale*scale
	if force || batch.scales[slot]!=world_scale {batch.scales[slot]=world_scale;changed=true}
	return changed
}

// Returns true only when packed instance streams change. Camera motion inside
// the cached safe region does no candidate scan or GPU upload. A scan outside
// that region still retains streams when the exact selection/scales are equal.
pack_visible_details :: proc(batch:^Terrain_Detail_Batch,detail:terrain.Detail,t:ecs.Transform,camera:[3]f32,chunked:bool=true) -> bool {
	batch.candidates_tested=0
	// Sparse prefixes would leave a reserved hole in nearly every small chunk,
	// multiplying instanced draws. Density batches compact into one ordered range.
	use_chunks:=chunked && !detail_density_enabled(detail)
	view:=Terrain_Detail_View{transform=t,camera=camera,draw_distance=detail.draw_distance,
		density_distance=detail.density_distance,density_min=detail.density_min,seed=detail.seed,
		grass=detail.kind=="grass",align_to_normal=detail.align_to_normal,chunked=use_chunks}
	previous:=batch.view
	previous.camera=camera
	static_unchanged:=batch.view_ready && previous==view && detail_candidates_current(batch,t,detail.align_to_normal,use_chunks)
	if static_unchanged {
		movement:=camera-batch.view.camera
		movement_squared:=#force_inline linalg.dot(movement,movement)
		if camera==batch.view.camera || (batch.camera_reuse_radius>0 &&
		   movement_squared<batch.camera_reuse_radius*batch.camera_reuse_radius) {
			for &chunk in batch.chunks {chunk.dirty=false}
			batch.visible_count=batch.cached_visible_count
			return false
		}
	}
	previous_count:=batch.cached_visible_count
	changed:=!static_unchanged
	batch.view=view; batch.view_ready=true
	batch.visible_count=0
	batch.camera_reuse_radius=math.inf_f32(1)
	prepare_detail_candidates(batch,t,detail.align_to_normal,use_chunks)
	if density_enabled:=detail_density_enabled(detail); density_enabled && !static_unchanged {
		for &candidate,source in batch.candidates {
			candidate.density_fade_start,candidate.density_cutoff=detail_density_cutoff(detail,source)
		}
	}
	if !static_unchanged {for &block in batch.blocks {block.ready=false}}
	if len(batch.instances)==0 {batch.cached_visible_count=0; return changed || previous_count!=0}
	fade_start:=detail.draw_distance*0.8
	density:=detail_density_enabled(detail)
	distance_scaled:=view.grass || density
	full_distance:=fade_start if view.grass else detail.draw_distance
	if density {full_distance=min(full_distance,detail.density_distance[0])}
	cutoff_squared:=detail.draw_distance*detail.draw_distance
	margin:=max(f32(0.0001),detail.draw_distance*0.00001)
	for &chunk in batch.chunks {
		chunk.dirty=false
		movement:=camera-chunk.camera
		movement_squared:=#force_inline linalg.dot(movement,movement)
		if static_unchanged && chunk.ready && (camera==chunk.camera ||
		   (chunk.camera_reuse_radius>0 && movement_squared<chunk.camera_reuse_radius*chunk.camera_reuse_radius)) {
			batch.visible_count+=chunk.visible_count
			// A reused chunk keeps its old anchor; account for the radius already
			// consumed. Fresh proofs below are centered on the current camera.
			movement_distance:=#force_inline math.sqrt(movement_squared)
			remaining:=max(f32(0),chunk.camera_reuse_radius-movement_distance)
			batch.camera_reuse_radius=min(batch.camera_reuse_radius,remaining)
			continue
		}
		old_count:=chunk.visible_count
		force:=!static_unchanged || !chunk.ready
		chunk.camera=camera;chunk.ready=true
		near_squared,far_squared:=#force_inline detail_chunk_distances(chunk.bounds,camera)
		if near_squared>=cutoff_squared {
			chunk.visible_count=0
			chunk.full=false
			near_distance:=#force_inline math.sqrt(near_squared)
			chunk.camera_reuse_radius=max(f32(0),near_distance-detail.draw_distance-margin)
			batch.camera_reuse_radius=min(batch.camera_reuse_radius,chunk.camera_reuse_radius)
			changed=changed || old_count!=0
			continue
		}
		far_distance:=#force_inline math.sqrt(far_squared)
		full:=far_squared<cutoff_squared && (!distance_scaled || far_distance<full_distance-margin)
		if full && chunk.full && !force && old_count==i32(chunk.count) {
			// Every root remains fully visible: retain this immutable stream range.
			radius:=full_distance-far_distance if distance_scaled else detail.draw_distance-far_distance
			chunk.camera_reuse_radius=max(f32(0),radius-margin)
			batch.camera_reuse_radius=min(batch.camera_reuse_radius,chunk.camera_reuse_radius)
			batch.visible_count+=chunk.visible_count
			continue
		}
		chunk.visible_count=0
		reuse_radius:=math.inf_f32(1)
		for &block in batch.blocks[chunk.block_offset:chunk.block_offset+chunk.block_count] {
			block_outside,block_full,block_radius:=#force_inline detail_block_classification(&block,camera,detail.draw_distance,cutoff_squared,full_distance,margin,distance_scaled,!force)
			if block_outside {
				reuse_radius=min(reuse_radius,block_radius)
				continue
			}
			if block_full {
				reuse_radius=min(reuse_radius,block_radius)
				slot:=chunk.offset+int(chunk.visible_count)
				// Selected source indices are strictly increasing. A range of n
				// slots with consecutive endpoints therefore contains every source
				// in this block, allowing unchanged model streams to stay untouched.
				if !distance_scaled && !force && int(chunk.visible_count)+block.count<=int(old_count) &&
				   batch.packed_indices[slot]==block.offset &&
				   batch.packed_indices[slot+block.count-1]==block.offset+block.count-1 {
					chunk.visible_count+=i32(block.count)
					continue
				}
				for source in block.offset..<block.offset+block.count {
					i:=chunk.offset+int(chunk.visible_count)
					if #force_inline pack_detail_candidate(batch,i,source,batch.instances[source].scale,t,force || chunk.visible_count>=old_count) {chunk.dirty=true}
					chunk.visible_count+=1
				}
				continue
			}
			batch.candidates_tested+=block.count
			for source in block.offset..<block.offset+block.count {
				instance:=batch.instances[source]
				delta:=batch.candidates[source].position-camera
				distance_squared:=#force_inline linalg.dot(delta,delta)
				distance:=#force_inline math.sqrt(distance_squared)
				reuse_radius=min(reuse_radius,abs(distance-detail.draw_distance)-margin)
				if view.grass {
					reuse_radius=min(reuse_radius,abs(distance-fade_start)-margin)
					if distance>=fade_start && distance_squared<cutoff_squared {reuse_radius=0}
				}
				if distance_squared>=cutoff_squared {continue}
				i:=chunk.offset+int(chunk.visible_count)
				scale:=instance.scale
				if view.grass {scale*=clamp((detail.draw_distance-distance)/(detail.draw_distance*0.2),0,1)}
				if density {
					candidate:=&batch.candidates[source]
					density_scale,density_radius:=#force_inline detail_density_visibility(candidate.density_fade_start,candidate.density_cutoff,distance,margin)
					reuse_radius=min(reuse_radius,density_radius)
					if density_scale<=0 {continue}
					scale*=density_scale
				}
				if #force_inline pack_detail_candidate(batch,i,source,scale,t,force || chunk.visible_count>=old_count) {chunk.dirty=true}
				chunk.visible_count+=1
			}
		}
		chunk.camera_reuse_radius=max(f32(0),reuse_radius)
		batch.camera_reuse_radius=min(batch.camera_reuse_radius,chunk.camera_reuse_radius)
		chunk.full=full
		changed=changed || chunk.dirty || chunk.visible_count!=old_count
		batch.visible_count+=chunk.visible_count
	}
	batch.cached_visible_count=batch.visible_count
	changed=changed || batch.visible_count!=previous_count
	return changed
}

upload_visible_details :: proc(batch:^Terrain_Detail_Batch,detail:terrain.Detail,t:ecs.Transform,camera:[3]f32,stats:^Render_Stats=nil,chunked:bool=true) -> (changed,uploaded:bool) {
	started:=rl.GetTime()
	changed=pack_visible_details(batch,detail,t,camera,chunked)
	if stats!=nil {
		stats.terrain_detail_pack_cpu_ms+=(rl.GetTime()-started)*1000
		stats.terrain_detail_candidates_tested+=batch.candidates_tested
	}
	if !changed {return}
	if batch.visible_count==0 {return}
	started=rl.GetTime()
	for chunk in batch.chunks {
		if !chunk.dirty || chunk.visible_count==0 {continue}
		uploaded=true
		if stats!=nil {stats.terrain_detail_chunk_uploads+=1}
		offset:=chunk.offset;count:=chunk.visible_count
		// A sole range replaces every live slot, so orphaning avoids waiting on
		// the previous GPU frame. Partial updates must preserve other chunks.
		discard:=len(batch.chunks)==1
		r3d.UploadInstances(batch.buffer,{.POSITION},i32(offset),count,raw_data(batch.positions[offset:]),discard)
		r3d.UploadInstances(batch.buffer,{.ROTATION},i32(offset),count,raw_data(batch.rotations[offset:]),discard)
		r3d.UploadInstances(batch.buffer,{.SCALE},i32(offset),count,raw_data(batch.scales[offset:]),discard)
		r3d.UploadInstances(batch.buffer,{.COLOR},i32(offset),count,raw_data(batch.colors[offset:]),discard)
	}
	if stats!=nil {stats.terrain_detail_upload_cpu_ms+=(rl.GetTime()-started)*1000}
	return
}

// Coalesce adjacent visible prefixes without crossing any reserved hole. The
// original candidate order is retained, including for transparent materials.
detail_visible_range :: proc(batch:^Terrain_Detail_Batch,start_chunk:int) -> (offset,count,next_chunk:int) {
	next_chunk=start_chunk
	for next_chunk<len(batch.chunks) && batch.chunks[next_chunk].visible_count==0 {next_chunk+=1}
	if next_chunk==len(batch.chunks) {return}
	chunk:=batch.chunks[next_chunk]
	offset=chunk.offset;count=int(chunk.visible_count);next_chunk+=1
	for next_chunk<len(batch.chunks) {
		chunk=batch.chunks[next_chunk]
		if chunk.visible_count==0 || chunk.offset!=offset+count {break}
		count+=int(chunk.visible_count);next_chunk+=1
	}
	return
}

draw_detail_ranges :: proc(batch:^Terrain_Detail_Batch,mesh:r3d.Mesh,material:r3d.Material,stats:^Render_Stats=nil) {
	started:=rl.GetTime()
	index:=0
	for index<len(batch.chunks) {
		offset,count,next:=detail_visible_range(batch,index)
		if count>0 {
			r3d.DrawMeshInstancedEx(mesh,material,batch.buffer,i32(offset),i32(count))
			if stats!=nil {stats.terrain_detail_draw_ranges+=1}
		}
		index=next
	}
	if stats!=nil {stats.terrain_detail_draw_cpu_ms+=(rl.GetTime()-started)*1000}
}

detail_chunking_enabled :: proc(material:r3d.Material) -> bool {
	// Native sorting may reorder separate transparent submissions, even when
	// their material matches. Keep those instances in one ordered draw range.
	return material.transparencyMode==.DISABLED
}

draw_terrain_details :: proc(ctx:^Context,world:^ecs.World,manager:^assets.Asset_Manager,camera:[3]f32,filter:Depth_Pass_Filter={}) {
	for entity,&cache in ctx.terrains {
		if depth_pass_excludes(world,entity,filter) {continue}
		for &batch in cache.details {batch.visible_count=0}
		if !ecs.is_enabled(world,entity) {continue}
		t,ok:=ecs.terrain_transform(world,entity); if !ok {continue}
		data,_,found:=ecs.terrain_runtime(world,entity); if !found {continue}
		for &batch,i in cache.details {
			if i>=len(data.description.details) {continue}
			detail:=data.description.details[i]
			material:=material_from_path(ctx,manager,detail.material,{255,255,255,255})
			if detail.material=="" {material.orm.roughness=0.9}
			changed,uploaded:=upload_visible_details(&batch,detail,t,camera,&ctx.frame_stats,detail_chunking_enabled(material))
			if changed {ctx.frame_stats.terrain_detail_rebuilds+=1}
			if uploaded {ctx.frame_stats.terrain_detail_uploads+=1}
			if batch.visible_count==0 {continue}
			if detail.kind=="model" {
				model,loaded:=load_model(ctx,manager,detail.model); if !loaded {continue}
				for mesh_index:i32=0; mesh_index<model.meshCount; mesh_index+=1 {
					mesh:=model.meshes[mesh_index]
					mesh.shadowCastMode=.ON_DOUBLE_SIDED if detail.shadows else .DISABLED
					draw_detail_ranges(&batch,mesh,material,&ctx.frame_stats)
				}
			} else {
				kind:=0 if detail.kind=="grass" else (1 if detail.kind=="tree" else 2)
				if !r3d.IsMeshValid(ctx.detail_meshes[kind]) {ctx.detail_meshes[kind]=make_detail_mesh(kind)}
				mesh:=ctx.detail_meshes[kind]
				if !r3d.IsMeshValid(mesh) {continue}
				mesh.shadowCastMode=.ON_DOUBLE_SIDED if detail.shadows else .DISABLED
				if kind==0 {material.cullMode=.NONE}
				draw_detail_ranges(&batch,mesh,material,&ctx.frame_stats)
			}
		}
	}
}
