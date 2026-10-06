package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

occlusion_frame :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,enabled:bool) -> rl.Image {
	ctx.occlusion_enabled=enabled
	sample(ctx,w,manager)
	return rl.LoadImageFromScreen()
}

assert_same_occlusion_pixels :: proc(a,b:rl.Image) {
	assert(a.width==b.width && a.height==b.height)
	before:=rl.LoadImageColors(a); defer rl.UnloadImageColors(before)
	after:=rl.LoadImageColors(b); defer rl.UnloadImageColors(after)
	for i in 0..<int(a.width*a.height) {assert(before[i]==after[i],"occlusion must preserve every visible pixel")}
}

validate_occlusion :: proc(ctx:^bridge.Context,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	w:=ecs.init(); defer ecs.destroy(&w)
	ctx.static_optimizations_disabled=false
	defer {ctx.occlusion_enabled=false}
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,camera,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&w,registry,camera,ecs.Camera3D{active=true,target={0,0,-1},up={0,1,0},fovy=60}))
	volume:=geometry.Volume{size={1,1,1},spacing=1,origin={-0.5,0,-0.5},cells=make([]u8,1)}
	defer delete(volume.cells); volume.cells[0]=1
	colors:=[2][4]u8{{},{255,255,255,255}}
	mesh,valid:=geometry.surface(volume,colors[:]); assert(valid); defer geometry.destroy_mesh(&mesh)
	path :: "occlusion-runtime.material.json"
	full_path :: "build/occlusion-runtime.material.json"
	defer os.remove(full_path)
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[230,60,20,255]}`)==nil)
	wall:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,wall,ecs.Transform{position={0,-2,-3},scale={4,4,0.1}}))
	assert(ecs.add(&w,registry,wall,ecs.MeshRenderer{primitive="static",material=path,color={255,255,255,255},shadows=false}))
	assert(ecs.set_static_mesh(&w,wall,mesh,collidable=false))
	hidden:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,hidden,ecs.Transform{position={0,-0.5,-7},scale={1,1,1}}))
	assert(ecs.set_static_mesh(&w,hidden,mesh,collidable=false))
	baseline:=occlusion_frame(ctx,&w,manager,false); defer rl.UnloadImage(baseline)
	optimized:=occlusion_frame(ctx,&w,manager,true); defer rl.UnloadImage(optimized)
	assert(ctx.static_meshes[hidden].occluded && !ctx.static_meshes[wall].occluded)
	assert(ctx.frame_stats.static_meshes_occluded==1 && ctx.frame_stats.static_shadow_only==1 && ctx.frame_stats.static_scene_triangles_avoided==12)
	assert(ctx.frame_stats.occlusion_cache_reused && ctx.frame_stats.occlusion_tests==0,"stationary frames reuse visibility results")
	assert_same_occlusion_pixels(baseline,optimized)
	assert(ecs.add(&w,registry,hidden,ecs.MeshRenderer{primitive="static",color={255,255,255,255},shadows=false}))
	sample(ctx,&w,manager)
	assert(ctx.frame_stats.static_submitted==1 && ctx.frame_stats.static_meshes_skipped==1 && ctx.frame_stats.static_shadow_only==0)
	// Disabling or moving the occluder must immediately restore the hidden mesh.
	assert(ecs.set_enabled(&w,wall,false)); sample(ctx,&w,manager)
	assert(!ctx.static_meshes[hidden].occluded)
	assert(ecs.set_enabled(&w,wall,true))
	assert(ecs.set_transform(&w,wall,ecs.Transform{position={5,-2,-3},scale={4,4,0.1}})); sample(ctx,&w,manager)
	assert(!ctx.static_meshes[hidden].occluded)
	assert(ecs.set_transform(&w,wall,ecs.Transform{position={0,-2,-3},scale={4,4,0.1}})); sample(ctx,&w,manager)
	assert(ctx.static_meshes[hidden].occluded)
	// Turning around cannot reuse the previous camera's occlusion decisions.
	view,_:=ecs.get_camera_3d(&w,camera); view.target={0,0,1}; assert(ecs.set_camera_3d(&w,camera,view)); sample(ctx,&w,manager)
	assert(!ctx.static_meshes[hidden].occluded)
	view.target={0,0,-1}; assert(ecs.set_camera_3d(&w,camera,view))
	// A material hot reload to transparent must fail open immediately.
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[230,60,20,128],"transparency":"alpha"}`)==nil)
	stale:=manager.materials[path]; stale.modified_time=-2; manager.materials[path]=stale; assets.refresh_materials(manager)
	sample(ctx,&w,manager); assert(!ctx.static_meshes[hidden].occluded)
	glass_baseline:=occlusion_frame(ctx,&w,manager,false); defer rl.UnloadImage(glass_baseline)
	glass_optimized:=occlusion_frame(ctx,&w,manager,true); defer rl.UnloadImage(glass_optimized)
	assert_same_occlusion_pixels(glass_baseline,glass_optimized)
	// Replacing the mesh with a doorway must not use its filled bounding box.
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[230,60,20,255]}`)==nil)
	stale=manager.materials[path]; stale.modified_time=-2; manager.materials[path]=stale; assets.refresh_materials(manager)
	doorway:=geometry.Volume{size={6,4,1},spacing=1,origin={-3,-2,-3},cells=make([]u8,24)}
	defer delete(doorway.cells)
	geometry.fill_box(doorway,{0,0,0},{2,4,1},1); geometry.fill_box(doorway,{4,0,0},{6,4,1},1)
	door_mesh,door_valid:=geometry.surface(doorway,colors[:]); assert(door_valid); defer geometry.destroy_mesh(&door_mesh)
	assert(ecs.set_transform(&w,wall,ecs.Transform{scale={1,1,1}}))
	assert(ecs.set_static_mesh(&w,wall,door_mesh,collidable=false)); sample(ctx,&w,manager)
	assert(!ctx.static_meshes[hidden].occluded,"geometry replacement must retain views through doors")
	door_baseline:=occlusion_frame(ctx,&w,manager,false); defer rl.UnloadImage(door_baseline)
	door_optimized:=occlusion_frame(ctx,&w,manager,true); defer rl.UnloadImage(door_optimized)
	assert_same_occlusion_pixels(door_baseline,door_optimized)
	fmt.println("PASS occlusion rejection, cache reuse, material reload, camera changes, and doorway pixels")
}

validate_occluded_shadow :: proc(ctx:^bridge.Context,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	w:=ecs.init(); defer ecs.destroy(&w)
	defer {ctx.occlusion_enabled=false}
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,camera,ecs.Transform{position={0,2,0},scale={1,1,1}}))
	assert(ecs.add(&w,registry,camera,ecs.Camera3D{active=true,target={0,0,-6},up={0,1,0},fovy=60}))
	ambient:=ecs.create_entity(&w); assert(ecs.add(&w,registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=0.1}))
	light:=ecs.create_entity(&w); assert(ecs.add(&w,registry,light,ecs.DirectionalLight{direction={1,-1,0},color={255,255,255,255},intensity=1,range=20,shadows=true,shadow_opacity=1,shadow_overrides={update_mode="continuous"}}))
	volume:=geometry.Volume{size={1,1,1},spacing=1,origin={-0.5,0,-0.5},cells=make([]u8,1)}
	defer delete(volume.cells); volume.cells[0]=1
	colors:=[2][4]u8{{},{255,255,255,255}}
	mesh,valid:=geometry.surface(volume,colors[:]); assert(valid); defer geometry.destroy_mesh(&mesh)
	floor:=ecs.create_entity(&w); assert(ecs.add(&w,registry,floor,ecs.Transform{position={0,-0.1,-6},scale={12,0.1,12}})); assert(ecs.set_static_mesh(&w,floor,mesh,collidable=false))
	wall:=ecs.create_entity(&w); assert(ecs.add(&w,registry,wall,ecs.Transform{position={0,-1,-3},scale={1.2,4,0.1}})); assert(ecs.set_static_mesh(&w,wall,mesh,collidable=false))
	caster:=ecs.create_entity(&w); assert(ecs.add(&w,registry,caster,ecs.Transform{position={0,0,-6},scale={1,2,1}})); assert(ecs.set_static_mesh(&w,caster,mesh,collidable=false))
	baseline:=occlusion_frame(ctx,&w,manager,false); defer rl.UnloadImage(baseline)
	optimized:=occlusion_frame(ctx,&w,manager,true); defer rl.UnloadImage(optimized)
	assert(ctx.static_meshes[caster].occluded && ctx.frame_stats.static_shadow_only>0,"the behind-wall caster must be culled from the scene")
	assert_same_occlusion_pixels(baseline,optimized)
	assert(ecs.set_enabled(&w,caster,false)); sample(ctx,&w,manager)
	without:=rl.LoadImageFromScreen(); defer rl.UnloadImage(without)
	a:=rl.LoadImageColors(baseline); defer rl.UnloadImageColors(a)
	b:=rl.LoadImageColors(without); defer rl.UnloadImageColors(b)
	changed:=0; for i in 0..<int(baseline.width*baseline.height) {if a[i]!=b[i] {changed+=1}}
	assert(changed>20,"the culled caster must cast a visible shadow outside the wall")
	fmt.println("PASS occluded object's visible shadow matches the unculled frame")
}
