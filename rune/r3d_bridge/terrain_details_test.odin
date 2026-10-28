package r3d_bridge

import "core:math"
import "core:math/linalg"
import "core:testing"
import "rune:ecs"
import "rune:terrain"
import r3d "r3d:r3d"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

detail_test_batch :: proc(instances: []terrain.Detail_Instance) -> Terrain_Detail_Batch {
	batch:=Terrain_Detail_Batch{instances=make([dynamic]terrain.Detail_Instance)}
	append(&batch.instances,..instances)
	batch.positions=make([]rl.Vector3,len(instances))
	batch.rotations=make([]rl.Quaternion,len(instances))
	batch.scales=make([]rl.Vector3,len(instances))
	batch.colors=make([]rl.Color,len(instances))
	return batch
}

// The uncached selection is the behavioral oracle: changing the camera or
// terrain pose must retain the same ordered roots and exact instance streams.
expect_detail_streams :: proc(t:^testing.T,batch:^Terrain_Detail_Batch,detail:terrain.Detail,pose:ecs.Transform,camera:[3]f32) {
	transform:=detail_transform(pose)
	terrain_rotation:=rotation_quaternion(pose)
	count:=0
	chunk_index,chunk_slot:=0,0
	for instance in batch.instances {
		world:=rl.Vector3Transform(instance.position,transform)
		delta:=world-camera
		distance_squared:=linalg.dot(delta,delta)
		if distance_squared>=detail.draw_distance*detail.draw_distance {continue}
		if !testing.expect(t,count<int(batch.visible_count),"every selected root has a packed slot") {return}
		for chunk_index<len(batch.chunks) && chunk_slot>=int(batch.chunks[chunk_index].visible_count) {
			chunk_index+=1;chunk_slot=0
		}
		if !testing.expect(t,chunk_index<len(batch.chunks),"visible chunk ranges cover every selected root") {return}
		slot:=batch.chunks[chunk_index].offset+chunk_slot
		rotation:=rl.QuaternionFromAxisAngle({0,1,0},instance.yaw)
		if detail.align_to_normal {
			normal:=linalg.normalize(instance.normal/pose.scale)
			rotation=rl.QuaternionFromVector3ToVector3({0,1,0},normal)*rotation
		}
		scale:=instance.scale
		if detail.kind=="grass" {
			distance:=math.sqrt(distance_squared)
			scale*=clamp((detail.draw_distance-distance)/(detail.draw_distance*0.2),0,1)
		}
		shade:=u8(instance.shade*255)
		testing.expect(t,batch.positions[slot]==world,"camera movement preserves root order and terrain attachment")
		testing.expect(t,batch.rotations[slot]==terrain_rotation*rotation,"compacting a changed selection preserves each root's rotation")
		testing.expect(t,batch.scales[slot]==pose.scale*scale,"distance fading and nonuniform terrain scale remain exact")
		testing.expect(t,batch.colors[slot]==rl.Color{shade,shade,shade,255},"a shifted packed slot keeps the source root's shade")
		count+=1;chunk_slot+=1
	}
	testing.expect(t,int(batch.visible_count)==count,"the exact draw-distance cutoff determines the visible count")
}

detail_test_chunked_batch :: proc() -> Terrain_Detail_Batch {
	count:=Terrain_Detail_Chunk_Capacity*3+37
	roots:=make([]terrain.Detail_Instance,count);defer delete(roots)
	for &root,i in roots {
		chunk,slot:=i/Terrain_Detail_Chunk_Capacity,i%Terrain_Detail_Chunk_Capacity
		x:=f32(slot%7)*0.02
		if chunk==1 {x=9.7+f32(slot)*0.005}
		if chunk==2 {x=-3+f32(slot%11)*0.03}
		if chunk==3 {x=30+f32(slot)*0.01}
		root={position={x,0,f32(slot%5)*0.01},normal=linalg.normalize([3]f32{0.2,1,0.1}),
			yaw=f32(i)*0.017,scale=0.7+f32(i%13)*0.03,shade=0.5+f32(i%17)*0.02}
	}
	return detail_test_batch(roots)
}

@(test)
terrain_detail_chunks_preserve_order_and_untouched_ranges :: proc(t:^testing.T) {
	batch:=detail_test_chunked_batch();defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	pack_visible_details(&batch,detail,pose,{})
	testing.expect(t,len(batch.chunks)==4,"a final short chunk keeps its own reserved range")
	expect_detail_streams(t,&batch,detail,pose,{})
	testing.expect(t,batch.chunks[0].visible_count==Terrain_Detail_Chunk_Capacity &&
		batch.chunks[1].visible_count>0 && batch.chunks[1].visible_count<Terrain_Detail_Chunk_Capacity &&
		batch.chunks[2].visible_count==Terrain_Detail_Chunk_Capacity && batch.chunks[3].visible_count==0,
		"full, boundary and excluded chunks retain exact root selection")
	first_positions:=make([]rl.Vector3,Terrain_Detail_Chunk_Capacity);defer delete(first_positions)
	third_rotations:=make([]rl.Quaternion,Terrain_Detail_Chunk_Capacity);defer delete(third_rotations)
	copy(first_positions,batch.positions[:Terrain_Detail_Chunk_Capacity])
	copy(third_rotations,batch.rotations[Terrain_Detail_Chunk_Capacity*2:Terrain_Detail_Chunk_Capacity*3])
	testing.expect(t,pack_visible_details(&batch,detail,pose,{0.4,0,0}),"walking changes only the roots crossing the cutoff")
	expect_detail_streams(t,&batch,detail,pose,{0.4,0,0})
	testing.expect(t,!batch.chunks[0].dirty && batch.chunks[1].dirty && !batch.chunks[2].dirty && !batch.chunks[3].dirty,
		"unchanged chunk ranges need no GPU update")
	for position,i in first_positions {testing.expect(t,batch.positions[i]==position,"packing a boundary chunk leaves the first range intact")}
	for rotation,i in third_rotations {testing.expect(t,batch.rotations[Terrain_Detail_Chunk_Capacity*2+i]==rotation,"packing a boundary chunk leaves later ranges intact")}
	for camera in ([6][3]f32{{5,0,0},{100,0,0},{-10,0,0},{0,8,0},{9.8,0,0},{0,0,0}}) {
		pack_visible_details(&batch,detail,pose,camera)
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
}

@(test)
terrain_detail_draw_ranges_coalesce_without_crossing_reserved_holes :: proc(t:^testing.T) {
	batch:=detail_test_chunked_batch();defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	pack_visible_details(&batch,detail,pose,{})
	offset,count,next:=detail_visible_range(&batch,0)
	testing.expect(t,offset==0 && count==Terrain_Detail_Chunk_Capacity+int(batch.chunks[1].visible_count) && next==2,
		"a full range joins the next visible prefix but stops at its unused reserved tail")
	offset,count,next=detail_visible_range(&batch,next)
	testing.expect(t,offset==Terrain_Detail_Chunk_Capacity*2 && count==Terrain_Detail_Chunk_Capacity && next>=3,
		"the next draw skips excluded ranges and retains source order")
	_,count,next=detail_visible_range(&batch,next)
	testing.expect(t,count==0 && next==len(batch.chunks),"the excluded tail contributes no draw")
	pack_visible_details(&batch,detail,pose,{5,0,0})
	offset,count,next=detail_visible_range(&batch,0)
	testing.expect(t,offset==0 && count==Terrain_Detail_Chunk_Capacity*3 && next>=3,
		"adjacent full chunks become one draw")
	pack_visible_details(&batch,detail,pose,{100,0,0})
	_,count,next=detail_visible_range(&batch,0)
	testing.expect(t,count==0 && next==len(batch.chunks),"an empty selection produces no draw ranges")
}

@(test)
terrain_detail_chunk_bounds_refresh_and_grass_fades_exactly :: proc(t:^testing.T) {
	batch:=detail_test_chunked_batch();defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="grass",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	for camera in ([5][3]f32{{0,0,0},{0.1,0,0},{1,0,0},{-1,0,0},{100,0,0}}) {
		pack_visible_details(&batch,detail,pose,camera)
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
	pose={position={2,0.8,-3},rotation={25,65,11},scale={1.7,0.6,0.8}}
	for aligned in ([2]bool{false,true}) {
		detail.align_to_normal=aligned
		pack_visible_details(&batch,detail,pose,{})
		expect_detail_streams(t,&batch,detail,pose,{})
	}
	detail.draw_distance=6
	pack_visible_details(&batch,detail,pose,{})
	expect_detail_streams(t,&batch,detail,pose,{})
}

detail_test_bounded_chunks :: proc(t:^testing.T,batch:^Terrain_Detail_Batch) {
	covered:=0
	for chunk in batch.chunks {
		testing.expect(t,chunk.offset==covered && chunk.count>0 && chunk.count<=Terrain_Detail_Chunk_Capacity,
			"chunk ranges cover the original candidate sequence without reordering")
		for axis in 0..<3 {
			testing.expect(t,chunk.bounds.max[axis]-chunk.bounds.min[axis]<=Terrain_Detail_Chunk_Span,
				"row wraps and terrain transforms do not create a wide chunk")
		}
		for index in chunk.offset..<chunk.offset+chunk.count {for axis in 0..<3 {
			position:=batch.candidates[index].position[axis]
			testing.expect(t,position>=chunk.bounds.min[axis] && position<=chunk.bounds.max[axis],
				"coarse distance bounds enclose every root in the reserved range")
		}}
		covered+=chunk.count
	}
	testing.expect(t,covered==len(batch.instances))
}

@(test)
terrain_detail_chunks_split_wide_rows_without_reordering_roots :: proc(t:^testing.T) {
	// A flat bed has rows wider than the spatial budget. The wrap from x=28
	// back to x=0 must start a new range rather than expanding the old bounds.
	roots:=make([]terrain.Detail_Instance,57*4);defer delete(roots)
	for &root,index in roots {
		column,row:=index%57,index/57
		root={position={f32(column)*0.5,f32(row)*0.02,f32(row)*0.5},
			normal=linalg.normalize([3]f32{0.1,1,0.15}),yaw=f32(index)*0.043,
			scale=0.8+f32(index%7)*0.05,shade=0.6+f32(index%11)*0.025}
	}
	batch:=detail_test_batch(roots);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=13}
	pose:=ecs.Transform{scale={1,1,1}}
	for camera in ([7][3]f32{{0,1,-2},{0.1,1,-2},{3,1,-2},{6,1,-2},{18,1,-2},{30,1,-2},{100,1,-2}}) {
		pack_visible_details(&batch,detail,pose,camera)
		detail_test_bounded_chunks(t,&batch)
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
	testing.expect(t,len(batch.chunks)>(len(roots)+Terrain_Detail_Chunk_Capacity-1)/Terrain_Detail_Chunk_Capacity,
		"spatial bounds split wide candidate rows before the capacity limit")
	pose={position={3,1,-4},rotation={10,37,5},scale={1.5,0.8,0.6}}
	detail.align_to_normal=true
	for camera in ([3][3]f32{{0,0,0},{3,1,-4},{15,1,-4}}) {
		pack_visible_details(&batch,detail,pose,camera)
		detail_test_bounded_chunks(t,&batch)
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
}

@(test)
terrain_detail_batch_reuse_keeps_its_original_safe_anchor :: proc(t:^testing.T) {
	roots:=[2]terrain.Detail_Instance{
		{position={0,0,0},normal={0,1,0},scale=1,shade=1},
		{position={2,0,0},normal={0,1,0},yaw=0.7,scale=1,shade=0.8},
	}
	batch:=detail_test_batch(roots[:]);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	pack_visible_details(&batch,detail,pose,{})
	anchor:=batch.view.camera
	radius:=batch.camera_reuse_radius
	testing.expect(t,radius>7,"the full batch has a conservative nonzero reuse radius")
	for step in 1..=7 {
		camera:=[3]f32{f32(step),0,0}
		testing.expect(t,!pack_visible_details(&batch,detail,pose,camera),"movement within the certified radius reuses every stream")
		testing.expect(t,batch.view.camera==anchor && batch.camera_reuse_radius==radius && batch.candidates_tested==0,
			"reusing a batch does not slide the proof anchor or enlarge its certified region")
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
	// This move leaves the original proof and crosses the first root's cutoff.
	testing.expect(t,pack_visible_details(&batch,detail,pose,{10.25,0,0}))
	testing.expect(t,batch.visible_count==1,"a sequence of small moves cannot retain a root past its draw distance")
	expect_detail_streams(t,&batch,detail,pose,{10.25,0,0})
}

@(test)
terrain_detail_unrolled_bounds_preserve_distance_proofs :: proc(t:^testing.T) {
	// Retain a separate axis-loop oracle for the scalar hot-path specialization.
	reference := proc(bounds:rl.BoundingBox,camera:[3]f32) -> (near_squared,far_squared:f32) {
		for axis in 0..<3 {
			low,high:=bounds.min[axis]-camera[axis],bounds.max[axis]-camera[axis]
			near:=max(low,0)+min(high,0)
			far:=max(abs(low),abs(high))
			near_squared+=near*near;far_squared+=far*far
		}
		return
	}
	boxes:=[5]rl.BoundingBox{
		{min={-2,0,-4},max={3,0,5}},
		{min={-1,-25,-0.125},max={1,40,0.25}},
		{min={3,4,0},max={3,4,0}},
		{min={99990,1001,-100010},max={100005,1007,-99999}},
		{min={-0.000001,-0.000002,-0.000003},max={0.000002,0.000003,0.000004}},
	}
	cameras:=[9][3]f32{{0,0,0},{-2,0,-4},{3,0,5},{-10,2,7},{4.9999995,0,0},
		{5,0,0},{5.0000005,0,0},{100000,1004,-100000},{0.0000001,-0.0000002,0.0000003}}
	for bounds in boxes {for camera in cameras {
		near,far:=detail_chunk_distances(bounds,camera)
		expected_near,expected_far:=reference(bounds,camera)
		testing.expect(t,near==expected_near && far==expected_far,"fixed-axis bounds retain exact left-associated squared distances")
		for cutoff in ([5]f32{0.01,1,5,10,140}) {
			squared:=cutoff*cutoff
			testing.expect(t,(near>=squared)==(expected_near>=squared) && (far<squared)==(expected_far<squared),
				"root bounds preserve strict cutoff inclusion at every tested scale")
		}
	}}
	near,far:=detail_chunk_distances(boxes[2],{})
	testing.expect(t,near==25 && far==25 && near>=25 && !(far<25),"a degenerate root exactly on its cutoff remains excluded")
	invalid:=[3]f32{math.nan_f32(),0,0}
	near,far=detail_chunk_distances(boxes[0],invalid)
	expected_near,expected_far:=reference(boxes[0],invalid)
	testing.expect(t,(near==expected_near || (math.is_nan(near) && math.is_nan(expected_near))) &&
		(far==expected_far || (math.is_nan(far) && math.is_nan(expected_far))),"invalid views retain the reference's nonfinite result")
	testing.expect(t,!(near>=25) && !(far<25),"a nonfinite view cannot prove a chunk fully outside or fully inside")
}

@(test)
terrain_detail_batch_reuse_respects_chunks_with_different_camera_anchors :: proc(t:^testing.T) {
	roots:=make([]terrain.Detail_Instance,2*Terrain_Detail_Chunk_Capacity);defer delete(roots)
	for &root,index in roots {
		x:=f32(index%Terrain_Detail_Chunk_Capacity)*0.002
		if index>=Terrain_Detail_Chunk_Capacity {x+=9}
		root={position={x,0,0},normal={0,1,0},yaw=f32(index)*0.03,scale=1,shade=0.6}
	}
	batch:=detail_test_batch(roots);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	mixed_anchors:=false
	for camera in ([9][3]f32{{0,0,0},{1.25,0,0},{1.5,0,0},{4,0,0},{4.25,0,0},{8,0,0},{10.2,0,0},{3,1,0},{-1,0,0}}) {
		pack_visible_details(&batch,detail,pose,camera)
		expect_detail_streams(t,&batch,detail,pose,camera)
		if !testing.expect(t,len(batch.chunks)==2,"the fixture has two independently reusable root ranges") {return}
		mixed_anchors=mixed_anchors || batch.chunks[0].camera!=batch.chunks[1].camera
		for chunk in batch.chunks {
			consumed:=batch.view.camera-chunk.camera
			remaining:=max(f32(0),chunk.camera_reuse_radius-math.sqrt(linalg.dot(consumed,consumed)))
			testing.expect(t,batch.camera_reuse_radius<=remaining+0.00001,
				"the batch proof fits inside every reused or freshly rebuilt chunk proof")
		}
	}
	testing.expect(t,mixed_anchors,"walking refreshes the boundary range while retaining a farther chunk's older proof")
}

@(test)
terrain_detail_compaction_tracks_coincident_candidate_identity :: proc(t:^testing.T) {
	roots:=[3]terrain.Detail_Instance{
		{position={0,0,0},normal={0,1,0},yaw=0.1,scale=1,shade=1},
		{position={2,0,0},normal={0,1,0},yaw=0.7,scale=1,shade=0.8},
		{position={2,0,0},normal={0,1,0},yaw=1.3,scale=1,shade=0.6},
	}
	batch:=detail_test_batch(roots[:]);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	pack_visible_details(&batch,detail,pose,{})
	expect_detail_streams(t,&batch,detail,pose,{})
	pack_visible_details(&batch,detail,pose,{10.25,0,0})
	testing.expect(t,batch.visible_count==2)
	expect_detail_streams(t,&batch,detail,pose,{10.25,0,0})
	testing.expect(t,batch.rotations[0]!=batch.rotations[1] && batch.colors[0]!=batch.colors[1],
		"coincident roots keep distinct rotations and shades when an earlier root leaves the packed prefix")
	pack_visible_details(&batch,detail,pose,{})
	expect_detail_streams(t,&batch,detail,pose,{})
}

@(test)
terrain_detail_leaf_bounds_skip_full_root_runs_inside_a_boundary_chunk :: proc(t:^testing.T) {
	roots:=make([]terrain.Detail_Instance,Terrain_Detail_Chunk_Capacity);defer delete(roots)
	for &root,index in roots {
		root={position={f32(index)*0.125,0,0},normal={0,1,0},yaw=f32(index)*0.07,
			scale=0.8+f32(index%7)*0.04,shade=0.5+f32(index%13)*0.025}
	}
	batch:=detail_test_batch(roots);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=5}
	pose:=ecs.Transform{scale={1,1,1}}
	for camera in ([5][3]f32{{0,0,0},{0.0625,0,0},{1.0625,0,0},{6.0625,0,0},{0,0,0}}) {
		pack_visible_details(&batch,detail,pose,camera)
		testing.expect(t,len(batch.chunks)==1 && batch.visible_count>0 && batch.visible_count<i32(len(roots)),
			"the fixture keeps a partially selected chunk")
		testing.expect(t,batch.candidates_tested<len(roots),"full and excluded leaf bounds avoid per-root distance scans")
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
	// Both ends now fall inside the chunk, requiring ordered compaction around
	// excluded prefix and suffix leaves as well as two exact boundary leaves.
	detail.draw_distance=2.5
	pack_visible_details(&batch,detail,pose,{3.9375,0,0})
	testing.expect(t,batch.candidates_tested<len(roots))
	expect_detail_streams(t,&batch,detail,pose,{3.9375,0,0})
	pose={position={1,0.5,-2},rotation={0,23,0},scale={0.8,1.2,0.9}}
	detail.kind="grass";detail.align_to_normal=true
	for camera in ([3][3]f32{{1,0.5,-2},{1.125,0.5,-2},{3,0.5,-2}}) {
		pack_visible_details(&batch,detail,pose,camera)
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
}

@(test)
terrain_detail_leaf_proofs_reuse_anchors_and_invalidate_after_view_edits :: proc(t:^testing.T) {
	roots:=make([]terrain.Detail_Instance,Terrain_Detail_Chunk_Capacity);defer delete(roots)
	for &root,index in roots {
		root={position={f32(index)*0.125,0,0},normal={0,1,0},yaw=f32(index)*0.07,scale=1,shade=0.8}
	}
	batch:=detail_test_batch(roots);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=5}
	pose:=ecs.Transform{scale={1,1,1}}
	pack_visible_details(&batch,detail,pose,{})
	if !testing.expect(t,len(batch.blocks)==8,"the fixture has full, boundary and excluded leaf ranges") {return}
	for camera in ([3][3]f32{{0.0625,0,0},{0.25,0,0},{0.5,0,0}}) {
		pack_visible_details(&batch,detail,pose,camera)
		expect_detail_streams(t,&batch,detail,pose,camera)
		testing.expect(t,batch.blocks[0].ready && batch.blocks[0].full && batch.blocks[0].camera==[3]f32{},
			"a fully visible leaf retains its original conservative camera anchor")
		testing.expect(t,batch.blocks[6].ready && batch.blocks[6].outside && batch.blocks[6].camera==[3]f32{},
			"an excluded leaf reuses its proof while another leaf crosses the draw boundary")
		testing.expect(t,batch.candidates_tested<=2*Terrain_Detail_Block_Capacity,
			"only boundary leaves evaluate individual root distances during a short walk")
	}
	// A view edit can skip the entire chunk. Its old leaf proofs must still be
	// invalidated before those leaves become relevant again on a later walk.
	detail.draw_distance=0.5
	pack_visible_details(&batch,detail,pose,{100,0,0})
	for block in batch.blocks {testing.expect(t,!block.ready,"a changed cutoff invalidates leaves skipped by coarse chunk culling")}
	pack_visible_details(&batch,detail,pose,{})
	testing.expect(t,batch.visible_count==4,"old full-leaf proofs cannot retain roots beyond a newly shortened cutoff")
	expect_detail_streams(t,&batch,detail,pose,{})
	detail.kind="grass";detail.draw_distance=5
	for camera in ([3][3]f32{{0,0,0},{0.0625,0,0},{0.5,0,0}}) {
		pack_visible_details(&batch,detail,pose,camera)
		expect_detail_streams(t,&batch,detail,pose,camera)
		testing.expect(t,!batch.blocks[4].ready,"fading grass leaves never retain a full-scale classification")
	}
}

@(test)
terrain_detail_single_range_policy_preserves_order_and_rebuilds_on_switch :: proc(t:^testing.T) {
	testing.expect(t,detail_chunking_enabled(r3d.Material{transparencyMode=.DISABLED}),"opaque details use bounded spatial ranges")
	testing.expect(t,!detail_chunking_enabled(r3d.Material{transparencyMode=.ALPHA}) &&
		!detail_chunking_enabled(r3d.Material{transparencyMode=.PREPASS}),"transparent detail instances retain one sorting unit")
	batch:=detail_test_chunked_batch();defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	for camera in ([3][3]f32{{0,0,0},{0.4,0,0},{10.25,0,0}}) {
		pack_visible_details(&batch,detail,pose,camera,chunked=false)
		testing.expect(t,len(batch.chunks)==1 && batch.chunks[0].offset==0 && batch.chunks[0].count==len(batch.instances),
			"order-sensitive materials retain a single instance range")
		expect_detail_streams(t,&batch,detail,pose,camera)
		offset,count,next:=detail_visible_range(&batch,0)
		testing.expect(t,offset==0 && count==int(batch.visible_count) && next==1)
	}
	pack_visible_details(&batch,detail,pose,{},chunked=true)
	testing.expect(t,len(batch.chunks)>1,"switching to chunked rendering rebuilds the reserved ranges")
	expect_detail_streams(t,&batch,detail,pose,{})
	pack_visible_details(&batch,detail,pose,{},chunked=false)
	testing.expect(t,len(batch.chunks)==1,"switching back discards the spatial chunk layout")
	expect_detail_streams(t,&batch,detail,pose,{})
}

when #config(RUNE_TERRAIN_DETAIL_GPU_TESTS,false) {
	detail_test_gpu_stream :: proc(t:^testing.T,buffer:u32,batch:^Terrain_Detail_Batch,expected:[]$T) {
		readback:=make([]T,len(expected));defer delete(readback)
		gl.BindBuffer(gl.ARRAY_BUFFER,buffer)
		gl.GetBufferSubData(gl.ARRAY_BUFFER,0,len(readback)*size_of(T),raw_data(readback))
		gl.BindBuffer(gl.ARRAY_BUFFER,0)
		for chunk in batch.chunks {for slot in chunk.offset..<chunk.offset+int(chunk.visible_count) {
			testing.expect(t,readback[slot]==expected[slot],"a partial upload preserves every visible range in the shared GPU buffer")
		}}
	}

	@(test)
	terrain_detail_partial_uploads_preserve_other_gpu_ranges :: proc(t:^testing.T) {
		rl.SetConfigFlags({.WINDOW_HIDDEN})
		rl.InitWindow(64,64,"Terrain detail partial upload regression");defer rl.CloseWindow()
		if !testing.expect(t,rl.IsWindowReady(),"native terrain buffer validation requires an OpenGL context") {return}
		gl.load_up_to(3,3,proc(p:rawptr,name:cstring){(^rawptr)(p)^=rlgl.GetProcAddress(name)})
		if !testing.expect(t,r3d.Init(64,64),"R3D initializes its instance-buffer API") {return}
		defer r3d.Close()
		batch:=detail_test_chunked_batch();defer release_detail_batch(&batch)
		batch.buffer=r3d.LoadInstanceBuffer(i32(len(batch.instances)),{.POSITION,.ROTATION,.SCALE,.COLOR})
		if !testing.expect(t,batch.buffer.capacity==i32(len(batch.instances)),"the test owns one shared detail buffer") {return}
		detail:=terrain.Detail{kind="model",draw_distance=10}
		pose:=ecs.Transform{scale={1,1,1}}
		for camera in ([6][3]f32{{0,0,0},{0.4,0,0},{5,0,0},{-10,0,0},{100,0,0},{0,0,0}}) {
			upload_visible_details(&batch,detail,pose,camera)
			expect_detail_streams(t,&batch,detail,pose,camera)
			detail_test_gpu_stream(t,batch.buffer.buffers[0],&batch,batch.positions)
			detail_test_gpu_stream(t,batch.buffer.buffers[1],&batch,batch.rotations)
			detail_test_gpu_stream(t,batch.buffer.buffers[2],&batch,batch.scales)
			detail_test_gpu_stream(t,batch.buffer.buffers[3],&batch,batch.colors)
			testing.expect(t,gl.GetError()==gl.NO_ERROR,"all reserved-range uploads and readbacks are valid OpenGL operations")
		}
		coincident:=[3]terrain.Detail_Instance{
			{position={0,0,0},normal={0,1,0},yaw=0.1,scale=1,shade=1},
			{position={2,0,0},normal={0,1,0},yaw=0.7,scale=1,shade=0.8},
			{position={2,0,0},normal={0,1,0},yaw=1.3,scale=1,shade=0.6},
		}
		duplicate_batch:=detail_test_batch(coincident[:]);defer release_detail_batch(&duplicate_batch)
		duplicate_batch.buffer=r3d.LoadInstanceBuffer(i32(len(duplicate_batch.instances)),{.POSITION,.ROTATION,.SCALE,.COLOR})
		if !testing.expect(t,duplicate_batch.buffer.capacity==3) {return}
		for camera in ([3][3]f32{{0,0,0},{10.25,0,0},{0,0,0}}) {
			upload_visible_details(&duplicate_batch,detail,pose,camera)
			expect_detail_streams(t,&duplicate_batch,detail,pose,camera)
			detail_test_gpu_stream(t,duplicate_batch.buffer.buffers[0],&duplicate_batch,duplicate_batch.positions)
			detail_test_gpu_stream(t,duplicate_batch.buffer.buffers[1],&duplicate_batch,duplicate_batch.rotations)
			detail_test_gpu_stream(t,duplicate_batch.buffer.buffers[2],&duplicate_batch,duplicate_batch.scales)
			detail_test_gpu_stream(t,duplicate_batch.buffer.buffers[3],&duplicate_batch,duplicate_batch.colors)
		}
	}
}

@(test)
terrain_detail_camera_cutoffs_preserve_packed_streams :: proc(t:^testing.T) {
	roots:=[7]terrain.Detail_Instance{}
	for &root,i in roots {
		root={position={f32(i)*2,0,0},normal={0,1,0},yaw=f32(i)*0.37,scale=0.7+f32(i)*0.1,shade=0.4+f32(i)*0.08}
	}
	batch:=detail_test_batch(roots[:]);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	testing.expect(t,pack_visible_details(&batch,detail,pose,{0,0,0}))
	testing.expect(t,batch.visible_count==5,"a root exactly at draw distance is excluded")
	expect_detail_streams(t,&batch,detail,pose,{0,0,0})
	testing.expect(t,!pack_visible_details(&batch,detail,pose,{0,0,0}),"a stationary camera retains its packed streams")
	for camera in ([7][3]f32{{0.001,0,0},{2.01,0,0},{12,0,0},{22,0,0},{100,0,0},{0,0,0},{-10,0,0}}) {
		pack_visible_details(&batch,detail,pose,camera)
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
	testing.expect(t,batch.visible_count==0,"entering an empty view clears the previous selection")
}

@(test)
terrain_detail_candidate_poses_refresh_for_transform_and_alignment :: proc(t:^testing.T) {
	roots:=[3]terrain.Detail_Instance{
		{position={1,0,2},normal=linalg.normalize([3]f32{0.3,1,0.2}),yaw=0.2,scale=0.8,shade=0.6},
		{position={-2,1,-1},normal=linalg.normalize([3]f32{-0.2,1,0.5}),yaw=1.2,scale=1.3,shade=0.8},
		{position={0,-1,3},normal={0,1,0},yaw=2.2,scale=0.9,shade=0.5},
	}
	batch:=detail_test_batch(roots[:]);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",draw_distance=100}
	camera:=[3]f32{0,2,0}
	for pose in ([4]ecs.Transform{
		{scale={1,1,1}},
		{position={3,1,-2},scale={1,1,1}},
		{position={3,1,-2},rotation={15,47,9},scale={1,1,1}},
		{position={3,1,-2},rotation={15,47,9},scale={2,0.7,1.3}},
	}) {
		for aligned in ([2]bool{false,true}) {
			detail.align_to_normal=aligned
			testing.expect(t,pack_visible_details(&batch,detail,pose,camera),"terrain pose or alignment changes invalidate candidate poses")
			expect_detail_streams(t,&batch,detail,pose,camera)
			testing.expect(t,!pack_visible_details(&batch,detail,pose,camera),"the refreshed pose is reusable")
		}
	}
}

@(test)
terrain_detail_grass_fade_tracks_camera_without_moving_roots :: proc(t:^testing.T) {
	roots:=[4]terrain.Detail_Instance{
		{position={0,0,0},normal={0,1,0},scale=1,shade=1},
		{position={8,0,0},normal={0,1,0},yaw=0.4,scale=1,shade=0.8},
		{position={9,0,0},normal={0,1,0},yaw=1.1,scale=1,shade=0.6},
		{position={10,0,0},normal={0,1,0},yaw=2.2,scale=1,shade=0.4},
	}
	batch:=detail_test_batch(roots[:]);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="grass",draw_distance=10}
	pose:=ecs.Transform{scale={1,1,1}}
	pack_visible_details(&batch,detail,pose,{0,0,0})
	testing.expect(t,batch.visible_count==3 && batch.scales[1]==rl.Vector3{1,1,1} && batch.scales[2]==rl.Vector3{0.5,0.5,0.5},"grass fades only in the outer fifth of its draw distance")
	for camera in ([5][3]f32{{0.01,0,0},{0.5,0,0},{-0.5,0,0},{2,0,0},{0,0,0}}) {
		testing.expect(t,pack_visible_details(&batch,detail,pose,camera),"moving within the fade band refreshes scales")
		expect_detail_streams(t,&batch,detail,pose,camera)
	}
	// Changing the draw distance is a selection change, not a terrain-pose edit.
	detail.draw_distance=8
	pack_visible_details(&batch,detail,pose,{0,0,0})
	testing.expect(t,batch.visible_count==1)
	expect_detail_streams(t,&batch,detail,pose,{0,0,0})
}
