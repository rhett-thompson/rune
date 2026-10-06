package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

validate_render_cache :: proc(ctx:^bridge.Context,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	w:=ecs.init(); defer ecs.destroy(&w)
	defer {ctx.render_optimizations_disabled=false}
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,camera,ecs.Transform{position={0,2,1},scale={1,1,1}}))
	assert(ecs.add(&w,registry,camera,ecs.Camera3D{active=true,target={0,0,-5},up={0,1,0},fovy=60}))
	parent:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,parent,ecs.Transform{position={0.1,0,-0.2},rotation={0,3,0},scale={1.1,0.9,1}}))
	path :: "render-cache-runtime.material.json"
	full_path :: "build/render-cache-runtime.material.json"
	defer os.remove(full_path)
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[150,100,60,255]}`)==nil)
	for primitive,i in ([3]string{"cube","plane","quad"}) {
		e:=ecs.create_entity(&w); assert(ecs.set_parent(&w,e,parent))
		assert(ecs.add(&w,registry,e,ecs.Transform{position={f32(i-1)*2,0,-5},rotation={12,7,4},scale={1,1.3,0.8}}))
		assert(ecs.add(&w,registry,e,ecs.MeshRenderer{primitive=primitive,color={255,255,255,255},material=path}))
	}
	sphere:=ecs.create_entity(&w); assert(ecs.set_parent(&w,sphere,parent))
	assert(ecs.add(&w,registry,sphere,ecs.Transform{position={0,1.4,-6},rotation={20,30,10},scale={1.1,0.7,1.3}}))
	assert(ecs.add(&w,registry,sphere,ecs.SphereRenderer{radius=0.7,color={255,255,255,255},material=path}))
	ctx.render_optimizations_disabled=true; sample(ctx,&w,manager)
	baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(baseline)
	assert(ctx.frame_stats.material_hashes==4,"baseline hashes each material draw")
	ctx.render_optimizations_disabled=false; sample(ctx,&w,manager)
	optimized:=rl.LoadImageFromScreen(); defer rl.UnloadImage(optimized)
	assert_same_occlusion_pixels(baseline,optimized)
	assert(ctx.frame_stats.render_entities==4 && ctx.frame_stats.render_transform_nodes==5)
	assert(ctx.frame_stats.render_list_rebuilds==0 && ctx.frame_stats.render_matrices_rebuilt==0)
	assert(ctx.frame_stats.material_hashes==0 && ctx.frame_stats.material_cache_hits==4)
	// A material reload must invalidate the shortcut, then become cached again.
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[30,150,210,255]}`)==nil)
	stale:=manager.materials[path]; stale.modified_time=-2; manager.materials[path]=stale; assets.refresh_materials(manager)
	sample(ctx,&w,manager)
	updated:=rl.LoadImageFromScreen(); defer rl.UnloadImage(updated)
	assert(rl.GetImageColor(updated,160,120)!=rl.GetImageColor(optimized,160,120),"hot reload changes the cached material's visible pixels")
	ctx.render_optimizations_disabled=true; sample(ctx,&w,manager)
	reloaded_baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(reloaded_baseline)
	assert_same_occlusion_pixels(updated,reloaded_baseline)
	cloud:=ecs.create_entity(&w); assert(ecs.set_parent(&w,cloud,parent))
	assert(ecs.add(&w,registry,cloud,ecs.Transform{position={0,0.8,-3.5},scale={2,1,1}}))
	cloud_data:=ecs.default_cloud_volume(); cloud_data.density=0.4; cloud_data.noise_scale=0.5; cloud_data.coverage=0.9
	assert(ecs.add(&w,registry,cloud,cloud_data))
	// Cached matrices must follow a moving, rotated, nonuniform parent.
	assert(ecs.set_transform(&w,parent,ecs.Transform{position={0.3,0.1,-0.5},rotation={5,8,3},scale={0.9,1.1,1.2}}))
	sample(ctx,&w,manager)
	moved_baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(moved_baseline)
	ctx.render_optimizations_disabled=false; sample(ctx,&w,manager)
	moved_cached:=rl.LoadImageFromScreen(); defer rl.UnloadImage(moved_cached)
	assert_same_occlusion_pixels(moved_baseline,moved_cached)
	assert(ctx.frame_stats.render_entities==5,"cloud-only entities participate in the cached render list")
	fmt.println("PASS render-list/matrix caching, primitive/cloud pixels, material hash reuse, and hot reload")
}
