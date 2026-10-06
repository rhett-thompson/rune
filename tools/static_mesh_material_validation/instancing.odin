package main

import "core:fmt"
import "core:math"
import "core:os"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// GPU quaternion arithmetic can quantize lit channels slightly differently
// from a precomputed CPU matrix; substantial changes still fail the check.
assert_instance_pixels :: proc(a,b:rl.Image) {
	before:=rl.LoadImageColors(a); defer rl.UnloadImageColors(before)
	after:=rl.LoadImageColors(b); defer rl.UnloadImageColors(after)
	changed,large:=0,0
	for i in 0..<int(a.width*a.height) {
		if before[i]!=after[i] {changed+=1}
		x,y:=before[i],after[i]
		if max(abs(int(x.r)-int(y.r)),abs(int(x.g)-int(y.g)),abs(int(x.b)-int(y.b)))>2 {large+=1}
	}
	assert(changed<int(a.width*a.height)/50 && large<8,"instanced rendering must preserve silhouettes and lighting")
}

validate_instancing :: proc(ctx:^bridge.Context,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	w:=ecs.init(); defer ecs.destroy(&w)
	defer {ctx.instancing_enabled=false; ctx.gpu_timing_enabled=false}
	ctx.render_optimizations_disabled=false; ctx.gpu_timing_enabled=true
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,camera,ecs.Transform{position={0,3,2},scale={1,1,1}}))
	assert(ecs.add(&w,registry,camera,ecs.Camera3D{active=true,target={0,0,-5},up={0,1,0},fovy=60}))
	ambient:=ecs.create_entity(&w); assert(ecs.add(&w,registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=0.5}))
	light:=ecs.create_entity(&w); assert(ecs.add(&w,registry,light,ecs.DirectionalLight{direction={-0.7,-1,0},color={255,255,255,255},intensity=0.8,range=20}))
	parent:=ecs.create_entity(&w); assert(ecs.add(&w,registry,parent,ecs.Transform{scale={1,1,1}}))
	props:[12]ecs.Entity
	for &e,i in props {
		e=ecs.create_entity(&w); assert(ecs.set_parent(&w,e,parent))
		assert(ecs.add(&w,registry,e,ecs.Transform{position={f32(i%4)-1.5,0,-f32(i/4)-4},scale={0.5,1.3,0.9}}))
		assert(ecs.add(&w,registry,e,ecs.MeshRenderer{primitive="cube",color={100,180,220,255},shadows=false}))
	}
	// Repeated static models share native mesh/material batches too.
	for i in 0..<2 {
		e:=ecs.create_entity(&w)
		assert(ecs.add(&w,registry,e,ecs.Transform{position={f32(i)-0.5,1.8,-5},scale={0.4,0.6,0.3}}))
		assert(ecs.add(&w,registry,e,ecs.ModelRenderer{model="../examples/textured_model_3d/assets/models/crate.obj",tint={210,140,70,255}}))
	}
	path :: "instance-alpha-runtime.material.json"
	full_path :: "build/instance-alpha-runtime.material.json"
	defer os.remove(full_path)
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[180,30,80,128],"transparency":"alpha"}`)==nil)
	for i in 0..<2 {
		e:=ecs.create_entity(&w)
		assert(ecs.add(&w,registry,e,ecs.Transform{position={f32(i)*0.2,0.5,-3-f32(i)*0.2},scale={2,2,1}}))
		assert(ecs.add(&w,registry,e,ecs.MeshRenderer{primitive="quad",material=path,color={255,255,255,255},shadows=false}))
	}
	ctx.instancing_enabled=false; sample(ctx,&w,manager)
	baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(baseline)
	draws:=ctx.frame_stats.prop_draws
	ctx.instancing_enabled=true; sample(ctx,&w,manager)
	optimized:=rl.LoadImageFromScreen(); defer rl.UnloadImage(optimized)
	assert_instance_pixels(baseline,optimized)
	assert(ctx.frame_stats.prop_instances>=12 && ctx.frame_stats.prop_draws_avoided>=8)
	assert(ctx.frame_stats.prop_draws+ctx.frame_stats.prop_draws_avoided==draws)
	assert(ctx.frame_stats.instance_uploads==0,"stationary batches reuse GPU buffers")
	assert(ctx.frame_stats.prop_batches_reused,"stationary props reuse membership and resolved batch keys")
	assert(ctx.frame_stats.gpu_supported && ctx.frame_stats.gpu_ready && ctx.frame_stats.gpu_backend_ms>0 && !math.is_inf(ctx.frame_stats.gpu_backend_ms),"GPU timestamp results must be available asynchronously")
	// Rotation and a moving nonuniform parent must update the instance streams.
	assert(ecs.set_transform(&w,parent,ecs.Transform{position={0.1,0.1,-0.2},rotation={8,12,4},scale={1.1,0.9,1.2}}))
	ctx.instancing_enabled=false; sample(ctx,&w,manager)
	moved_baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(moved_baseline)
	ctx.instancing_enabled=true; sample(ctx,&w,manager)
	moved_cached:=rl.LoadImageFromScreen(); defer rl.UnloadImage(moved_cached)
	assert_instance_pixels(moved_baseline,moved_cached)
	assert(ecs.set_enabled(&w,props[0],false)); assert(ecs.destroy_entity(&w,props[1])); sample(ctx,&w,manager)
	assert(ctx.frame_stats.prop_draws+ctx.frame_stats.prop_draws_avoided==draws-2)
	// Hot-reloading a transparent material to opaque changes eligibility.
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[180,30,80,255]}`)==nil)
	stale:=manager.materials[path]; stale.modified_time=-2; manager.materials[path]=stale; assets.refresh_materials(manager)
	ctx.instancing_enabled=false; sample(ctx,&w,manager)
	opaque_baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(opaque_baseline)
	ctx.instancing_enabled=true; sample(ctx,&w,manager)
	opaque_instanced:=rl.LoadImageFromScreen(); defer rl.UnloadImage(opaque_instanced)
	assert_instance_pixels(opaque_baseline,opaque_instanced)
	fmt.println("PASS primitive/model instancing, nonuniform lighting, transparency, live edits, hot reload, and GPU timestamps")
}

validate_instanced_shadows :: proc(ctx:^bridge.Context,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	w:=ecs.init(); defer ecs.destroy(&w)
	defer {ctx.instancing_enabled=false}
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,camera,ecs.Transform{position={0,3,0},scale={1,1,1}}))
	assert(ecs.add(&w,registry,camera,ecs.Camera3D{active=true,target={0,0,-5},up={0,1,0},fovy=50}))
	ambient:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=0.1}))
	light:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,light,ecs.DirectionalLight{direction={-1,-1,0},color={255,255,255,255},intensity=1,range=20,shadows=true,shadow_opacity=1,shadow_overrides={update_mode="continuous"}}))
	floor:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,floor,ecs.Transform{position={0,-0.05,-5},scale={20,0.1,20}}))
	assert(ecs.add(&w,registry,floor,ecs.MeshRenderer{primitive="cube",color={255,255,255,255},shadows=true}))
	casters:[2]ecs.Entity
	for &e,i in casters {
		e=ecs.create_entity(&w)
		assert(ecs.add(&w,registry,e,ecs.Transform{position={5,2,-5-f32(i)},scale={1,2,1}}))
		assert(ecs.add(&w,registry,e,ecs.MeshRenderer{primitive="cube",color={255,255,255,255},shadows=true}))
	}
	ctx.instancing_enabled=false; sample(ctx,&w,manager)
	baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(baseline)
	frustum:=r3d.GetFrustum()
	for _,i in casters {
		z:=-5-f32(i)
		assert(!r3d.FrustumIntersectsBoundingBox(&frustum,{{4.5,1,z-0.5},{5.5,3,z+0.5}}),"shadow fixture casters must be fully outside the camera")
	}
	ctx.instancing_enabled=true; sample(ctx,&w,manager)
	optimized:=rl.LoadImageFromScreen(); defer rl.UnloadImage(optimized)
	assert(ctx.frame_stats.instanced_batches==1 && ctx.frame_stats.prop_instances==2)
	assert_instance_pixels(baseline,optimized)
	for e in casters {assert(ecs.set_enabled(&w,e,false))}
	sample(ctx,&w,manager)
	without:=rl.LoadImageFromScreen(); defer rl.UnloadImage(without)
	before:=rl.LoadImageColors(baseline); defer rl.UnloadImageColors(before)
	after:=rl.LoadImageColors(without); defer rl.UnloadImageColors(after)
	changed:=0
	for i in 0..<int(baseline.width*baseline.height) {if before[i]!=after[i] {changed+=1}}
	assert(changed>20,"camera-hidden instance batches must still cast visible shadows")
	fmt.println("PASS instanced off-camera shadow casters")
}
