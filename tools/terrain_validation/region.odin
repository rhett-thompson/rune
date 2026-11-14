package main

import "core:fmt"
import "core:math"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import bridge "rune:r3d_bridge"
import b3 "vendor:box3d"
import rl "vendor:raylib"

Region_Resolution :: 25
Region_Asset :: "build/terrain-region.terrain.json"
Region_Heightmap :: "build/terrain-region.r16"
Region_Reference_Asset :: "build/terrain-region-reference.terrain.json"
Region_Reference_Heightmap :: "build/terrain-region-reference.r16"

write_region_heightmap :: proc(path: string, heights: [Region_Resolution*Region_Resolution]u16) {
	bytes: [Region_Resolution*Region_Resolution*2]u8
	for h,i in heights {
		bytes[2*i] = u8(h & 255)
		bytes[2*i+1] = u8(h >> 8)
	}
	assert(write_fixture(path,bytes[:])==nil)
}

write_region_fixture :: proc(asset, heightmap: string, heights: [Region_Resolution*Region_Resolution]u16 = {}) {
	write_region_heightmap(heightmap,heights)
	descriptor := fmt.tprintf(`{{"heightmap":"%s","resolution":[25,25],"size":[24,24],"height_scale":65535,"chunk_cells":8,"details":[{{"kind":"rock","count":64,"draw_distance":100}}]}}`,heightmap)
	assert(write_fixture(asset,descriptor)==nil)
}

add_region_terrain :: proc(w: ^ecs.World, r: ^ecs.Component_Registry, asset: string, x: f32 = 0) -> ecs.Entity {
	e := ecs.create_entity(w)
	assert(add_transform(w,r,e,{position={x,0,0},scale={1,1,1}}))
	settings := ecs.default_terrain()
	settings.asset = asset
	assert(ecs.add(w,r,e,settings))
	return e
}

raycast_region_height :: proc(w: ^ecs.World, e: ecs.Entity, x, z: f32) -> f32 {
	hit,found := ecs.physics_3d_raycast(w,{x,20,z},{0,-40,0})
	assert(found && hit.entity==e && hit.component=="Terrain")
	return hit.point[1]
}

validate_region_collision :: proc(r: ^ecs.Component_Registry) {
	write_region_fixture(Region_Asset,Region_Heightmap)
	manager := assets.Asset_Manager{root=".",terrains=make(map[string]assets.Terrain_Asset),retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
	defer assets.shutdown(&manager)
	w := ecs.init(); defer ecs.destroy(&w)
	e := add_region_terrain(&w,r,Region_Asset)
	sibling := add_region_terrain(&w,r,Region_Asset,32)
	assert(!ecs.update_terrain_region(&w,e,0,0,1,1,{1}),"reject edits before the terrain loads")
	ecs.sync_terrains(&w,&manager)
	assert(math.abs(raycast_region_height(&w,e,7.75,8.25))<0.001)
	_,initial_revision,loaded := ecs.terrain_runtime(&w,e)
	assert(loaded)
	assert(!ecs.update_terrain_region(&w,e,-1,0,1,1,{1,2}))
	assert(!ecs.update_terrain_region(&w,e,9,8,8,9,nil))
	assert(!ecs.update_terrain_region(&w,e,8,8,8,9,nil))
	assert(!ecs.update_terrain_region(&w,e,24,24,26,25,{1,2}))
	assert(!ecs.update_terrain_region(&w,e,8,8,10,9,{1}))
	assert(!ecs.update_terrain_region(&w,e,8,8,9,9,{1,2}))
	for invalid in ([5]f32{math.nan_f32(),math.inf_f32(1),math.inf_f32(-1),-100001,200001}) {
		assert(!ecs.update_terrain_region(&w,e,7,8,9,9,{1,invalid}),"validate the complete patch before editing")
	}
	assert(ecs.update_terrain_region(&w,e,7,8,9,9,{0,0}))
	data,revision,_ := ecs.terrain_runtime(&w,e)
	_,dirty := ecs.terrain_dirty_region(&w,e)
	assert(!dirty && revision==initial_revision && data.heights[8*Region_Resolution+7]==0,"invalid and no-op patches preserve samples and revision")
	assert(ecs.commit_terrain_region(&w,e),"committing with no pending edit is a no-op")

	assert(ecs.update_terrain_region(&w,e,7,8,9,10,{1,5,2,3}))
	assert(ecs.update_terrain_region(&w,e,24,24,25,25,{4}),"end bounds may equal the resolution")
	region,pending := ecs.terrain_dirty_region(&w,e)
	assert(pending && region==(terrain.Sample_Rect{7,8,25,25}),"pending sample bounds union across edits")
	ecs.sync_terrains(&w,&manager)
	data,_,_ = ecs.terrain_runtime(&w,e)
	assert(data.heights[8*Region_Resolution+7]==1 && data.heights[8*Region_Resolution+8]==5)
	assert(data.heights[9*Region_Resolution+7]==2 && data.heights[9*Region_Resolution+8]==3,"patch samples use row-major order")
	assert(data.heights[24*Region_Resolution+24]==4)
	height,inside := terrain.sample_height(data,7.75,8.25)
	assert(inside && height>1,"preview heights are immediately available")
	assert(math.abs(raycast_region_height(&w,e,7.75,8.25))<0.001,"collision keeps the old surface until commit")
	other,_,_ := ecs.terrain_runtime(&w,sibling)
	assert(other.heights[8*Region_Resolution+8]==0,"editing one instance preserves others using the same asset")

	reference_heights: [Region_Resolution*Region_Resolution]u16
	reference_heights[8*Region_Resolution+7] = 1
	reference_heights[8*Region_Resolution+8] = 5
	reference_heights[9*Region_Resolution+7] = 2
	reference_heights[9*Region_Resolution+8] = 3
	reference_heights[24*Region_Resolution+24] = 4
	write_region_fixture(Region_Reference_Asset,Region_Reference_Heightmap,reference_heights)
	reference := add_region_terrain(&w,r,Region_Reference_Asset,64)
	ecs.sync_terrains(&w,&manager)
	assert(ecs.commit_terrain_region(&w,e))
	_,dirty = ecs.terrain_dirty_region(&w,e)
	assert(!dirty,"commit clears the pending region")
	data,_,_ = ecs.terrain_runtime(&w,e)
	for point in ([6][2]f32{{7.25,8.25},{7.75,8.75},{8,8.25},{8.25,8.25},{23.75,23.75},{3.25,4.25}}) {
		x,z := point[0],point[1]
		expected := raycast_region_height(&w,reference,64+x,z)
		sample,inside := terrain.sample_height(data,x,z)
		assert(inside && math.abs(sample-expected)<0.001)
		assert(math.abs(raycast_region_height(&w,e,x,z)-expected)<0.001,"committed collision matches a full asset rebuild")
	}

	assert(ecs.update_terrain_region(&w,e,8,8,9,9,{9}))
	assert(write_fixture(Region_Heightmap,"broken")==nil)
	assets.refresh_terrains(&manager)
	ecs.sync_terrains(&w,&manager)
	data,_,_ = ecs.terrain_runtime(&w,e)
	_,dirty = ecs.terrain_dirty_region(&w,e)
	assert(dirty && data.heights[8*Region_Resolution+8]==9,"invalid reload retains the preview and pending edit")
	assert(math.abs(raycast_region_height(&w,e,8,8)-5)<0.001,"invalid reload retains committed collision")
	write_region_heightmap(Region_Heightmap,{})
	assets.refresh_terrains(&manager)
	ecs.sync_terrains(&w,&manager)
	data,_,_ = ecs.terrain_runtime(&w,e)
	_,dirty = ecs.terrain_dirty_region(&w,e)
	assert(!dirty && data.heights[8*Region_Resolution+8]==0 && math.abs(raycast_region_height(&w,e,8,8))<0.001,"valid file reload replaces preview and collision")
	assert(ecs.update_terrain_region(&w,e,0,0,3,1,{1,2,3}))
	data,_,_ = ecs.terrain_runtime(&w,e)
	assert(ecs.update_terrain_region(&w,e,1,0,4,1,data.heights[:3]))
	data,_,_ = ecs.terrain_runtime(&w,e)
	assert(data.heights[1]==1 && data.heights[2]==2 && data.heights[3]==3,"overlapping borrowed input is read before applying the patch")
	if b3.HUGE() < 150000 {
		assert(ecs.update_terrain_region(&w,e,8,8,9,9,{150000}))
		assert(!ecs.commit_terrain_region(&w,e),"a preview outside the native height limit cannot replace collision")
		data,_,_ = ecs.terrain_runtime(&w,e)
		_,dirty = ecs.terrain_dirty_region(&w,e)
		assert(dirty && data.heights[8*Region_Resolution+8]==150000 && math.abs(raycast_region_height(&w,e,8,8))<0.001)
		assert(ecs.update_terrain_region(&w,e,8,8,9,9,{5}) && ecs.commit_terrain_region(&w,e),"a failed commit can be repaired and retried")
		assert(math.abs(raycast_region_height(&w,e,8,8)-5)<0.001)
	}
	fmt.println("PASS terrain region validation, per-entity preview, collision commit, full-rebuild parity and file reload")
}

region_chunk_offsets :: proc(ctx: ^bridge.Context, e: ecs.Entity) -> [9][2]i32 {
	result: [9][2]i32
	cache := ctx.terrains[e]
	assert(len(cache.chunks)==len(result))
	for mesh,i in cache.chunks {result[i]={mesh.vertexOffset,mesh.indexOffset}}
	return result
}

check_region_render :: proc(ctx: ^bridge.Context, w: ^ecs.World, manager: ^assets.Asset_Manager, e: ecs.Entity, changed: bit_set[0..=8]) {
	before := region_chunk_offsets(ctx,e)
	render_frame(ctx,w,manager)
	after := region_chunk_offsets(ctx,e)
	expected_count := 0
	for i in 0..<len(before) {
		expected := i in changed
		if expected {expected_count += 1}
		assert((before[i]!=after[i])==expected,fmt.tprintf("unexpected GPU mesh replacement for terrain chunk %d",i))
	}
	assert(ctx.frame_stats.terrain_chunks_built==expected_count,"build only the invalidated chunks")
}

validate_region_rendering :: proc(ctx: ^bridge.Context, manager: ^assets.Asset_Manager, r: ^ecs.Component_Registry) {
	write_region_fixture(Region_Asset,Region_Heightmap)
	w := ecs.init(); defer ecs.destroy(&w)
	e := add_region_terrain(&w,r,Region_Asset)
	camera := ecs.create_entity(&w)
	assert(add_transform(&w,r,camera,{position={30,18,30},scale={1,1,1}}))
	assert(ecs.add_component(&w,r,camera,"Camera3D",parse(`{"active":true,"target":[12,0,12]}`)))
	ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	detail_buffer := ctx.terrains[e].details[0].buffer.buffers[0]
	assert(detail_buffer!=0)

	assert(ecs.update_terrain_region(&w,e,3,3,4,4,{2}))
	check_region_render(ctx,&w,manager,e,{0})
	assert(ecs.update_terrain_region(&w,e,7,3,8,4,{3}))
	check_region_render(ctx,&w,manager,e,{0,1}) // Chunk 1 shares a normal, not a changed position.
	assert(ecs.update_terrain_region(&w,e,7,7,8,8,{3}))
	check_region_render(ctx,&w,manager,e,{0,1,3}) // A diagonally adjacent normal is unaffected.
	assert(ecs.update_terrain_region(&w,e,8,8,9,9,{4}))
	check_region_render(ctx,&w,manager,e,{0,1,3,4})
	assert(ecs.update_terrain_region(&w,e,3,19,4,20,{5}))
	assert(ecs.update_terrain_region(&w,e,19,19,20,20,{6}))
	check_region_render(ctx,&w,manager,e,{6,8})
	assert(ctx.terrains[e].details[0].buffer.buffers[0]==detail_buffer,"preview leaves detail placement in place")
	check_region_render(ctx,&w,manager,e,{})

	assert(ecs.commit_terrain_region(&w,e))
	check_region_render(ctx,&w,manager,e,{})
	assert(ctx.terrains[e].details[0].buffer.buffers[0]!=detail_buffer,"commit refreshes detail placement")
	data,_,_ := ecs.terrain_runtime(&w,e)
	assert_region_details(ctx,e,data)
	assert(ecs.update_terrain_region(&w,e,24,24,25,25,{7}))
	assert(ecs.commit_terrain_region(&w,e))
	check_region_render(ctx,&w,manager,e,{8}) // Commit before rendering must not lose the visual change.
	data,_,_ = ecs.terrain_runtime(&w,e)
	committed := terrain.clone(data); defer terrain.destroy(&committed)
	assert(ecs.update_terrain_region(&w,e,3,3,4,4,{8}))
	other := ecs.init(); defer ecs.destroy(&other)
	rl.BeginDrawing()
	assert(!bridge.draw_scene(ctx,&other,manager),"an empty World clears the bridge terrain cache")
	rl.EndDrawing()
	assert(len(ctx.terrains)==0)
	render_frame(ctx,&w,manager)
	assert(ctx.frame_stats.terrain_chunks_built==9 && ctx.terrains[e].chunks[0].aabb.max[1]==8,"new render cache uses the latest preview")
	assert_region_details(ctx,e,committed)
	write_region_heightmap(Region_Heightmap,{})
	assets.refresh_terrains(manager)
	ecs.sync_terrains(&w,manager)
	check_region_render(ctx,&w,manager,e,{0,1,2,3,4,5,6,7,8})
	assert(ctx.terrains[e].chunks[0].aabb.max[1]==0,"full reload replaces a rendered preview")
	fmt.println("PASS terrain region GPU chunk reuse, seam normals, queued edits and detail commit")
}

assert_region_details :: proc(ctx: ^bridge.Context, e: ecs.Entity, data: terrain.Data) {
	expected := terrain.scatter_details(data,data.description.details[0]); defer delete(expected)
	actual := ctx.terrains[e].details[0].instances
	assert(len(actual)==len(expected),"detail count matches committed terrain")
	for detail,i in actual {assert(detail==expected[i],"detail placement matches committed terrain")}
}
