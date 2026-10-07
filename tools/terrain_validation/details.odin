package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

validate_detail_scatter :: proc() {
	d:=terrain.default_description(); d.heightmap="test.r16"; d.resolution={3,3}; d.size={16,16}
	heights:=[9]f32{0,1,2,0,1,2,0,1,2}
	data:=terrain.Data{description=d,heights=heights[:]}
	rule:=terrain.default_detail("rock"); rule.count=100; rule.seed=42
	a:=terrain.scatter_details(data,rule); defer delete(a)
	b:=terrain.scatter_details(data,rule); defer delete(b)
	assert(len(a)==100 && len(a)==len(b),"unrestricted scatter count")
	for point,i in a {
		assert(point==b[i],"scatter seed is deterministic")
		y,ok:=terrain.sample_height(data,point.position[0],point.position[2])
		assert(ok && math.abs(point.position[1]-y)<0.00001,"detail roots sit on exact terrain triangles")
		assert(point.scale>=rule.scale[0] && point.scale<=rule.scale[1])
		assert(point.normal[0]<0 && point.normal[1]>0.9,"detail normal follows slope")
	}
	rule.seed+=1
	c:=terrain.scatter_details(data,rule); defer delete(c)
	assert(c[0].position!=a[0].position,"new seed changes placements")
	rule.height={10,20}
	rejected:=terrain.scatter_details(data,rule); assert(len(rejected)==0); delete(rejected)
	rule.height={-100,100}; rule.slope={30,90}
	rejected=terrain.scatter_details(data,rule); assert(len(rejected)==0); delete(rejected)
	prefix:=`{"heightmap":"tools/terrain_validation/fixtures/precision.png","resolution":[2,2],"details":`
	for details in ([]string{
		`null`,`[12]`,`[{"kind":"unknown"}]`,`[{"kind":"model"}]`,`[{"kind":"grass","model":"x"}]`,
		`[{"count":100001}]`,`[{"count":-1}]`,`[{"seed":-1}]`,`[{"count":1.5}]`,`[{"unexpected":1}]`,
		`[{"scale":[2,1]}]`,`[{"height":[2,1]}]`,`[{"slope":[0,91]}]`,`[{"draw_distance":0}]`,`[{"shadows":1}]`,
	}) {
		assert(write_fixture("build/details-invalid.terrain.json",fmt.tprint(prefix,details,"}"))==nil)
		loaded,_,error:=terrain.load(".","build/details-invalid.terrain.json"); assert(error!="","reject invalid scatter configuration"); terrain.destroy(&loaded)
	}
	assert(write_fixture("build/details-valid.terrain.json",fmt.tprint(prefix,`[{"kind":"tree","name":"Pines"},{"kind":"rock"}]} `))==nil)
	loaded,_,error:=terrain.load(".","build/details-valid.terrain.json"); assert(error=="",error)
	assert(loaded.description.details[0].shadows && !loaded.description.details[0].align_to_normal && loaded.description.details[1].align_to_normal,"kind-specific defaults")
	copy:=terrain.clone(loaded); terrain.destroy(&loaded)
	assert(copy.description.details[0].name=="Pines" && copy.description.details[1].kind=="rock","detail strings are owned by clones")
	terrain.destroy(&copy)
	fmt.println("PASS deterministic detail scatter, triangle placement, slope/height filters, validation and ownership")
}

validate_detail_rendering :: proc(ctx:^bridge.Context,manager:^assets.Asset_Manager,r:^ecs.Component_Registry) {
	d:=terrain.default_description(); d.heightmap="build/terrain-test.r16"; d.resolution={17,17}; d.size={16,16}; d.height_scale=0
	rules:=[4]terrain.Detail{terrain.default_detail("grass"),terrain.default_detail("tree"),terrain.default_detail("rock"),terrain.default_detail("model")}
	for &rule in rules {rule.count=32; rule.draw_distance=100}
	rules[0].draw_distance=35 // Exercise grass fading as well as full-size instances.
	rules[3].model="build/terrain-detail.obj"; rules[3].seed=96
	rules[3].material="build/terrain-detail.material.json"
	assert(write_fixture(rules[3].model,"v -0.3 0 0\nv 0.3 0 0\nv 0 1 0\nf 1 2 3\n")==nil)
	assert(write_fixture(rules[3].material,`{"base_color":[240,90,35,255],"lighting":false,"cull":"none"}`)==nil)
	d.details=rules[:]
	path:="build/details-render.terrain.json"
	bytes,_:=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
	w:=ecs.init(); defer ecs.destroy(&w)
	e:=ecs.create_entity(&w); assert(add_transform(&w,r,e,{position={-8,0,-8},scale={1,1,1}}))
	t:=ecs.default_terrain(); t.asset=path; assert(ecs.add(&w,r,e,t)); ecs.sync_terrains(&w,manager)
	camera:=ecs.create_entity(&w); assert(add_transform(&w,r,camera,{position={12,10,16},scale={1,1,1}}))
	assert(ecs.add_component(&w,r,camera,"Camera3D",parse(`{"active":true,"target":[0,1,0],"fovy":55}`)))
	sun:=ecs.create_entity(&w); assert(ecs.add_component(&w,r,sun,"DirectionalLight",parse(`{"direction":[-1,-1,-1],"energy":3}`)))
	blend_center_pixel(ctx,&w,manager,output="build/terrain-details-test.png")
	for batch in ctx.terrains[e].details {
		assert(len(batch.instances)==32 && batch.visible_count==32 && batch.buffer.capacity==32,"GPU instances draw each detail type")
	}
	assert(ctx.frame_stats.terrain_detail_rebuilds==4 && ctx.frame_stats.terrain_detail_uploads==4,"first view uploads all detail streams")
	render_frame(ctx,&w,manager)
	assert(ctx.frame_stats.terrain_detail_rebuilds==0 && ctx.frame_stats.terrain_detail_uploads==0,"stationary view reuses visible instances and GPU streams")
	cache:=ctx.terrains[e]
	terrain_pose,_:=ecs.get_transform(&w,e)
	camera_pose,_:=ecs.get_transform(&w,camera)
	validate_detail_staging(&cache.details[0],rules[0],terrain_pose,camera_pose.position)
	view,_:=ecs.get_camera_3d(&w,camera)
	turned_view:=view; turned_view.target[0]+=1
	assert(ecs.set_camera_3d(&w,camera,turned_view)); render_frame(ctx,&w,manager)
	assert(ctx.frame_stats.terrain_detail_rebuilds==0,"camera orientation does not change distance-based detail selection")
	assert(ecs.set_camera_3d(&w,camera,view))
	assert(ecs.set_enabled(&w,e,false)); render_frame(ctx,&w,manager)
	for batch in ctx.terrains[e].details {assert(batch.visible_count==0,"disabled terrain has no visible details")}
	assert(ecs.set_enabled(&w,e,true)); render_frame(ctx,&w,manager)
	for batch in ctx.terrains[e].details {assert(batch.visible_count==32,"re-enabling restores cached visibility")}
	assert(ctx.frame_stats.terrain_detail_rebuilds==0 && ctx.frame_stats.terrain_detail_uploads==0,"re-enabling reuses unchanged GPU streams")
	for mesh in ctx.detail_meshes {assert(mesh.vertexCount>0,"built-in detail mesh uploads")}
	assert(ctx.models[rules[3].model].model.meshCount>0,"custom detail model loads and instances")
	validate_detail_world_registration(ctx,&w,manager,e,camera)
	pose,_:=ecs.get_transform(&w,camera); pose.position={1000,1000,1000}; assert(ecs.set_transform(&w,camera,pose))
	render_frame(ctx,&w,manager)
	for batch in ctx.terrains[e].details {assert(batch.visible_count==0,"distant details are culled")}
	assert(ctx.frame_stats.terrain_detail_rebuilds==4 && ctx.frame_stats.terrain_detail_uploads==0,"camera translation rebuilds visibility without uploading empty streams")
	render_frame(ctx,&w,manager)
	assert(ctx.frame_stats.terrain_detail_rebuilds==0,"all-culled visibility is cached too")
	old:=ctx.terrains[e].details[0].buffer.buffers[0]
	assert(write_fixture(path,"invalid")==nil); assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].details[0].buffer.buffers[0]==old,"invalid reload retains detail buffers")
	assert(ctx.frame_stats.terrain_detail_rebuilds==0,"invalid reload retains the visibility cache")
	assert(ecs.set_transform(&w,camera,camera_pose))
	rules[0].count=12; rules[1].count=0
	bytes,_=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager); render_frame(ctx,&w,manager)
	assert(len(ctx.terrains[e].details[0].instances)==12 && ctx.terrains[e].details[0].buffer.buffers[0]!=old,"valid detail edits regenerate GPU instances")
	assert(ctx.frame_stats.terrain_detail_rebuilds==4 && ctx.frame_stats.terrain_detail_uploads==3,"reload invalidates cached streams and supports an empty detail definition")
	assert(ctx.terrains[e].details[0].visible_count==12 && ctx.terrains[e].details[1].visible_count==0)
	render_frame(ctx,&w,manager)
	assert(ctx.frame_stats.terrain_detail_rebuilds==0,"empty detail batches reuse their cache")
	assert(ecs.destroy_entity(&w,e)); render_frame(ctx,&w,manager)
	assert(len(ctx.terrains)==0,"terrain removal releases detail batches")
	// Replacement must release populated staging arrays as well as GPU buffers.
	e=ecs.create_entity(&w); assert(add_transform(&w,r,e,terrain_pose))
	assert(ecs.add(&w,r,e,t)); ecs.sync_terrains(&w,manager); render_frame(ctx,&w,manager)
	other:=ecs.init(); defer ecs.destroy(&other)
	rl.BeginDrawing(); bridge.draw_scene(ctx,&other,manager); rl.EndDrawing()
	assert(len(ctx.terrains)==0,"world replacement releases detail caches")
	fmt.println("PASS instanced details, unchanged-view reuse, allocation-free staging, activation, distance culling, reload and cleanup")
}

// Track both Odin allocators around just the detail preparation path: renderer
// bookkeeping outside this function can legitimately use frame scratch.
validate_detail_staging :: proc(batch:^bridge.Terrain_Detail_Batch,detail:terrain.Detail,t:ecs.Transform,camera:[3]f32) {
	tracker:mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker,context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator=mem.tracking_allocator(&tracker)
	context.temp_allocator=context.allocator
	positions:=raw_data(batch.positions)
	rotations:=raw_data(batch.rotations)
	scales:=raw_data(batch.scales)
	colors:=raw_data(batch.colors)
	for _ in 0..<8 {assert(!bridge.upload_visible_details(batch,detail,t,camera),"unchanged detail inputs skip all rebuilding/uploading")}
	assert(bridge.upload_visible_details(batch,detail,t,camera+[3]f32{1,0,0}),"moving the camera invalidates the view")
	moved:=t; moved.position[1]+=2
	assert(bridge.upload_visible_details(batch,detail,moved,camera),"moving terrain invalidates the streams")
	assert(batch.positions[0][1]==t.position[1]+2,"reused staging contains the new world position")
	clipped:=detail; clipped.draw_distance=1
	assert(bridge.upload_visible_details(batch,clipped,t,camera) && batch.visible_count==0,"draw distance changes invalidate visibility")
	assert(!bridge.upload_visible_details(batch,clipped,t,camera),"all-culled batches reuse their empty result")
	aligned:=detail; aligned.align_to_normal=!detail.align_to_normal
	assert(bridge.upload_visible_details(batch,aligned,t,camera),"alignment changes invalidate rotations")
	assert(bridge.upload_visible_details(batch,detail,t,camera),"restore the original streams")
	assert(batch.visible_count==32)
	assert(raw_data(batch.positions)==positions && raw_data(batch.rotations)==rotations && raw_data(batch.scales)==scales && raw_data(batch.colors)==colors,"changed views reuse staging storage")
	assert(tracker.total_allocation_count==0,"stable and moving detail views use no per-frame heap or scratch allocations")
}

// Translating the terrain and camera together must leave the rendered image
// unchanged, including while grass is shrinking at its draw-distance boundary.
// This catches applying a terrain offset inside an instance's rotation/scale.
validate_detail_world_registration :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,e,camera:ecs.Entity) {
	terrain_pose,_:=ecs.get_transform(w,e)
	camera_pose,_:=ecs.get_transform(w,camera)
	view,_:=ecs.get_camera_3d(w,camera)
	defer {
		assert(ecs.set_transform(w,e,terrain_pose))
		assert(ecs.set_transform(w,camera,camera_pose))
		assert(ecs.set_camera_3d(w,camera,view))
	}
	shift:=[3]f32{-128,7,64}
	for variant in 0..<3 {
		base:=terrain_pose
		if variant==2 {base.rotation={12,37,-7}; base.scale={1.4,0.8,1.1}}
		pose:=camera_pose
		if variant==1 {pose.position+={5,0,0}}
		assert(ecs.set_transform(w,e,base))
		assert(ecs.set_transform(w,camera,pose))
		assert(ecs.set_camera_3d(w,camera,view))
		before:=capture_detail_frame(ctx,w,manager)
		base.position+=shift; pose.position+=shift
		moved_view:=view; moved_view.target+=shift
		assert(ecs.set_transform(w,e,base))
		assert(ecs.set_transform(w,camera,pose))
		assert(ecs.set_camera_3d(w,camera,moved_view))
		after:=capture_detail_frame(ctx,w,manager)
		changed:=0
		for y:i32=0; y<before.height; y+=1 {for x:i32=0; x<before.width; x+=1 {
			a,b:=rl.GetImageColor(before,x,y),rl.GetImageColor(after,x,y)
			if abs(int(a.r)-int(b.r))+abs(int(a.g)-int(b.g))+abs(int(a.b)-int(b.b))>24 {changed+=1}
		}}
		rl.UnloadImage(before); rl.UnloadImage(after)
		fmt.println("Detail world-registration variant",variant,"changed pixels:",changed)
		assert(changed<640*360/100,"terrain details stay registered to the ground under world translation, camera movement and fading")
	}
	fmt.println("PASS rendered detail world registration with moving cameras, fading, rotated and scaled terrain")
}

capture_detail_frame :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager) -> rl.Image {
	rl.BeginDrawing()
	defer rl.EndDrawing()
	assert(bridge.draw_scene(ctx,w,manager))
	rlgl.DrawRenderBatchActive()
	return rl.LoadImageFromScreen()
}
