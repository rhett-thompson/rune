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

// Use the authored density curve directly as an uncached selection oracle.
// This also checks source identity: packed-slot hashes would reshuffle roots.
density_test_expect_selection :: proc(t:^testing.T,batch:^Terrain_Detail_Batch,detail:terrain.Detail,pose:ecs.Transform,camera:[3]f32) {
	transform:=detail_transform(pose)
	terrain_rotation:=rotation_quaternion(pose)
	count,chunk_index,chunk_slot:=0,0,0
	for instance,source in batch.instances {
		world:=rl.Vector3Transform(instance.position,transform)
		delta:=world-camera
		distance:=math.sqrt(linalg.dot(delta,delta))
		if distance>=detail.draw_distance {continue}
		if detail.density_distance[1]>detail.density_distance[0] && detail.density_min<1 {
			progress:=clamp((distance-detail.density_distance[0])/(detail.density_distance[1]-detail.density_distance[0]),0,1)
			density:=1-progress*(1-detail.density_min)
			if terrain.detail_random(u32(detail.seed),u32(source),5)>=density {continue}
		}
		for chunk_index<len(batch.chunks) && chunk_slot>=int(batch.chunks[chunk_index].visible_count) {
			chunk_index+=1;chunk_slot=0
		}
		if !testing.expect(t,chunk_index<len(batch.chunks),"every retained density root has a visible reserved slot") {return}
		slot:=batch.chunks[chunk_index].offset+chunk_slot
		rotation:=rl.QuaternionFromAxisAngle({0,1,0},instance.yaw)
		if detail.align_to_normal {
			normal:=linalg.normalize(instance.normal/pose.scale)
			rotation=rl.QuaternionFromVector3ToVector3({0,1,0},normal)*rotation
		}
		shade:=u8(instance.shade*255)
		testing.expect(t,batch.packed_indices[slot]==source,"density compacts a stable ordered subset of the original source roots")
		testing.expect(t,batch.positions[slot]==world && batch.rotations[slot]==terrain_rotation*rotation,
			"density changes preserve ground attachment and each retained root's orientation")
		testing.expect(t,batch.colors[slot]==rl.Color{shade,shade,shade,255},"compaction retains the source shade")
		for axis in 0..<3 {
			testing.expect(t,batch.scales[slot][axis]>0 && batch.scales[slot][axis]<=pose.scale[axis]*instance.scale,
				"retained density roots have positive scales bounded by their authored size")
		}
		count+=1;chunk_slot+=1
	}
	testing.expect(t,count==int(batch.visible_count),"the direct density curve determines the retained population")
}

density_test_expect_same_streams :: proc(t:^testing.T,cached,fresh:^Terrain_Detail_Batch) {
	testing.expect(t,cached.visible_count==fresh.visible_count && len(cached.chunks)==len(fresh.chunks),
		"cached density selection agrees with a fresh uncached batch")
	if len(cached.chunks)!=len(fresh.chunks) {return}
	for chunk,index in cached.chunks {
		other:=fresh.chunks[index]
		if !testing.expect(t,chunk.offset==other.offset && chunk.visible_count==other.visible_count) {continue}
		for slot in chunk.offset..<chunk.offset+int(chunk.visible_count) {
			testing.expect(t,cached.packed_indices[slot]==fresh.packed_indices[slot] &&
				cached.positions[slot]==fresh.positions[slot] && cached.rotations[slot]==fresh.rotations[slot] &&
				cached.scales[slot]==fresh.scales[slot] && cached.colors[slot]==fresh.colors[slot],
				"reusing movement proofs cannot retain stale density roots or fading scales")
		}
	}
}

@(test)
terrain_detail_density_keeps_near_grass_and_stable_nested_far_subsets :: proc(t:^testing.T) {
	roots:=make([]terrain.Detail_Instance,1024);defer delete(roots)
	for &root,index in roots {
		root={normal={0,1,0},yaw=f32(index)*0.013,scale=1,shade=0.5+f32(index%17)*0.02}
	}
	batch:=detail_test_batch(roots);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",seed=42,draw_distance=100,density_distance={10,60},density_min=0.25}
	pose:=ecs.Transform{scale={1,1,1}}
	pack_visible_details(&batch,detail,pose,{})
	testing.expect(t,batch.visible_count==i32(len(roots)),"grass near the camera retains its full authored density")
	previous:=make([]bool,len(roots));defer delete(previous)
	for &value in previous {value=true}
	for distance in ([5]f32{15,30,45,61,75}) {
		camera:=[3]f32{distance,0,0}
		pack_visible_details(&batch,detail,pose,camera)
		density_test_expect_selection(t,&batch,detail,pose,camera)
		current:=make([]bool,len(roots))
		for chunk in batch.chunks {for slot in chunk.offset..<chunk.offset+int(chunk.visible_count) {
			source:=batch.packed_indices[slot]
			testing.expect(t,previous[source],"moving farther away removes roots without substituting new ones")
			current[source]=true
		}}
		copy(previous,current);delete(current)
		testing.expect(t,!pack_visible_details(&batch,detail,pose,camera) && batch.candidates_tested==0,
			"a stationary camera reuses its density streams")
	}
	testing.expect(t,batch.visible_count>i32(len(roots)/5) && batch.visible_count<i32(len(roots)*3/10),
		"the far population approaches the authored 25 percent density")
	offset,count,next:=detail_visible_range(&batch,0)
	testing.expect(t,offset==0 && count==int(batch.visible_count) && next==len(batch.chunks),
		"distance thinning keeps all retained roots in one instanced draw range")
	testing.expect(t,len(batch.chunks)==1,"density does not fragment sparse roots into small reserved draw ranges")
	pack_visible_details(&batch,detail,pose,{})
	testing.expect(t,batch.visible_count==i32(len(roots)),"returning to the bed restores every original root")
	density_test_expect_selection(t,&batch,detail,pose,{})
}

@(test)
terrain_detail_density_shrinks_before_culling_without_moving_the_root :: proc(t:^testing.T) {
	roots:=[1]terrain.Detail_Instance{{normal={0,1,0},yaw=0.7,scale=1,shade=0.8}}
	batch:=detail_test_batch(roots[:]);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",seed=42,draw_distance=100,density_distance={10,60},density_min=0}
	pose:=ecs.Transform{position={3,2,-4},scale={1,1,1}}
	rank:=terrain.detail_random(u32(detail.seed),0,5)
	cutoff:=detail.density_distance[0]+(1-rank)*(detail.density_distance[1]-detail.density_distance[0])
	start:=max(detail.density_distance[0],cutoff-min(f32(2),(detail.density_distance[1]-detail.density_distance[0])*0.1))
	camera:=pose.position+[3]f32{(start+cutoff)*0.5,0,0}
	pack_visible_details(&batch,detail,pose,camera)
	if !testing.expect(t,batch.visible_count==1,"a root remains submitted while it shrinks out") {return}
	testing.expect(t,batch.positions[0]==pose.position,"the fade stays anchored to the authored ground pivot")
	testing.expect(t,abs(batch.scales[0].x-0.5)<0.0001,"halfway through the short fade the root is half size")
	testing.expect(t,pack_visible_details(&batch,detail,pose,camera+[3]f32{0.001,0,0}),
		"small camera movements update scales while a root is fading")
	pack_visible_details(&batch,detail,pose,pose.position+[3]f32{cutoff+0.001,0,0})
	testing.expect(t,batch.visible_count==0,"fully faded roots stop contributing geometry")
	pack_visible_details(&batch,detail,pose,pose.position)
	testing.expect(t,batch.visible_count==1 && batch.scales[0]==rl.Vector3{1,1,1},"a return walk restores the same full-size root")
}

@(test)
terrain_detail_density_caches_match_fresh_selection_across_camera_and_view_changes :: proc(t:^testing.T) {
	batch:=detail_test_chunked_batch();defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",seed=42,draw_distance=40,density_distance={2,18},density_min=0.25}
	for chunked in ([2]bool{true,false}) {
		for pose in ([2]ecs.Transform{
			{scale={1,1,1}},
			{position={3,1,-4},rotation={10,37,5},scale={1.5,0.8,0.6}},
		}) {
			for kind in ([2]string{"model","grass"}) {
				detail.kind=kind;detail.align_to_normal=true
				for camera in ([10][3]f32{{0,0,0},{0.05,0,0},{1,0,0},{4,0,0},{8,0,0},{20,0,0},{45,0,0},{100,0,0},{4,0,0},{0,0,0}}) {
					pack_visible_details(&batch,detail,pose,camera,chunked)
					fresh:=detail_test_batch(batch.instances[:])
					pack_visible_details(&fresh,detail,pose,camera,chunked)
					density_test_expect_same_streams(t,&batch,&fresh)
					density_test_expect_selection(t,&batch,detail,pose,camera)
					release_detail_batch(&fresh)
				}
			}
		}
	}
	pose:=ecs.Transform{scale={1,1,1}}
	camera:=[3]f32{12,0,0}
	detail.kind="model"
	for variant in 0..<5 {
		switch variant {
		case 1: detail.seed=71
		case 2: detail.density_distance={4,25}
		case 3: detail.density_min=0.6
		case 4: detail.density_distance={0,0}
		}
		pack_visible_details(&batch,detail,pose,camera)
		fresh:=detail_test_batch(batch.instances[:])
		pack_visible_details(&fresh,detail,pose,camera)
		density_test_expect_same_streams(t,&batch,&fresh)
		density_test_expect_selection(t,&batch,detail,pose,camera)
		release_detail_batch(&fresh)
	}
}

@(test)
terrain_detail_density_zero_one_and_disabled_preserve_expected_limits :: proc(t:^testing.T) {
	roots:=[4]terrain.Detail_Instance{
		{normal={0,1,0},scale=1,shade=1},
		{position={1,0,0},normal={0,1,0},scale=1,shade=1},
		{position={2,0,0},normal={0,1,0},scale=1,shade=1},
		{position={3,0,0},normal={0,1,0},scale=1,shade=1},
	}
	batch:=detail_test_batch(roots[:]);defer release_detail_batch(&batch)
	detail:=terrain.Detail{kind="model",seed=42,draw_distance=100,density_distance={10,30},density_min=0}
	pose:=ecs.Transform{scale={1,1,1}}
	camera:=[3]f32{40,0,0}
	pack_visible_details(&batch,detail,pose,camera)
	testing.expect(t,batch.visible_count==0,"zero minimum removes every root beyond the density band")
	detail.density_min=1
	pack_visible_details(&batch,detail,pose,camera)
	testing.expect(t,batch.visible_count==4,"a minimum of one keeps the full population")
	expect_detail_streams(t,&batch,detail,pose,camera)
	detail.density_min=0.25;detail.density_distance={0,0}
	pack_visible_details(&batch,detail,pose,camera)
	testing.expect(t,batch.visible_count==4,"omitted distance settings preserve existing detail behavior")
	expect_detail_streams(t,&batch,detail,pose,camera)
	pack_visible_details(&batch,detail,pose,{200,0,0})
	testing.expect(t,batch.visible_count==0,"density settings never bypass the final draw distance")
}

when #config(RUNE_TERRAIN_DETAIL_GPU_TESTS,false) {
	@(test)
	terrain_detail_density_single_range_uploads_preserve_all_gpu_streams :: proc(t:^testing.T) {
		rl.SetConfigFlags({.WINDOW_HIDDEN})
		rl.InitWindow(64,64,"Terrain density upload regression");defer rl.CloseWindow()
		if !testing.expect(t,rl.IsWindowReady(),"density buffer validation requires an OpenGL context") {return}
		gl.load_up_to(3,3,proc(p:rawptr,name:cstring){(^rawptr)(p)^=rlgl.GetProcAddress(name)})
		if !testing.expect(t,r3d.Init(64,64),"R3D initializes its density instance buffers") {return}
		defer r3d.Close()
		roots:=make([]terrain.Detail_Instance,256);defer delete(roots)
		for &root,index in roots {
			root={position={f32(index%16)*0.02,0,f32(index/16)*0.02},normal={0,1,0},
				yaw=f32(index)*0.017,scale=0.8+f32(index%7)*0.05,shade=0.5+f32(index%17)*0.02}
		}
		batch:=detail_test_batch(roots);defer release_detail_batch(&batch)
		batch.buffer=r3d.LoadInstanceBuffer(i32(len(roots)),{.POSITION,.ROTATION,.SCALE,.COLOR})
		if !testing.expect(t,batch.buffer.capacity==i32(len(roots)),"the test owns one full-capacity buffer per instance stream") {return}
		detail:=terrain.Detail{kind="model",seed=42,draw_distance=40,density_distance={2,18},density_min=0.2}
		pose:=ecs.Transform{scale={1,1,1}}
		for camera,index in ([6][3]f32{{0,0,0},{8,0,0},{8.01,0,0},{25,0,0},{100,0,0},{0,0,0}}) {
			_,uploaded:=upload_visible_details(&batch,detail,pose,camera)
			testing.expect(t,len(batch.chunks)==1 && batch.chunks[0].offset==0,
				"density compacts into one range without reserved holes between small chunks")
			density_test_expect_selection(t,&batch,detail,pose,camera)
			if index==0 || index==5 {
				testing.expect(t,batch.visible_count==i32(len(roots)) && uploaded,"the near population uploads every source root")
			}
			if index==3 {testing.expect(t,batch.visible_count>0 && batch.visible_count<i32(len(roots)/2),"the distant prefix contains the sparse minimum subset")}
			if index==4 {testing.expect(t,batch.visible_count==0 && !uploaded,"an empty density selection submits no GPU write")}
			detail_test_gpu_stream(t,batch.buffer.buffers[0],&batch,batch.positions)
			detail_test_gpu_stream(t,batch.buffer.buffers[1],&batch,batch.rotations)
			detail_test_gpu_stream(t,batch.buffer.buffers[2],&batch,batch.scales)
			detail_test_gpu_stream(t,batch.buffer.buffers[3],&batch,batch.colors)
			testing.expect(t,gl.GetError()==gl.NO_ERROR,"single-range rewrites leave all four GPU attribute streams valid")
			changed,uploaded_again:=upload_visible_details(&batch,detail,pose,camera)
			testing.expect(t,!changed && !uploaded_again,"an unchanged density view neither repacks nor rewrites its GPU streams")
		}
	}
}
