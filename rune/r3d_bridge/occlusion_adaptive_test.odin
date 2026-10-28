package r3d_bridge

import "core:math"
import "core:testing"
import "rune:assets"
import "rune:ecs"
import rl "vendor:raylib"

occlusion_adaptive_test_view :: proc(ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager,frame:int,width:i32=320,height:i32=240,finish:bool=true) {
	camera:=[3]f32{f32(frame)*0.001,0,0}
	projection:=rl.MatrixPerspective(60*math.PI/180,1,0.1,100)
	view:=projection*rl.MatrixTranslate(-camera[0],0,0)
	ctx.frame_stats={}
	prepare_occlusion_view(ctx,w,manager,camera,view,nil,1,width,height)
	if finish {finish_occlusion_frame(ctx)}
}

occlusion_adaptive_test_enter_skip :: proc(t:^testing.T,ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager,frame:^int) {
	for _ in 0..<8 {
		frame^+=1
		occlusion_adaptive_test_view(ctx,w,manager,frame^)
		if ctx.frame_stats.occlusion_probe_skipped {return}
	}
	testing.expect(t,false,"an unhelpful changing view enters bounded fail-open backoff")
}

@(test)
occlusion_adaptive_backoff_is_opt_in_bounded_and_clears_hidden_flags :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache);ctx.occlusion_enabled=true
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	front:=occlusion_test_cached_quad(ctx,&w,&r,-3,1.2)
	for frame in 0..<7 {
		occlusion_adaptive_test_view(ctx,&w,nil,frame)
		testing.expect(t,ctx.occlusion.count==1 && !ctx.frame_stats.occlusion_probe_skipped && !ctx.static_meshes[front].occluded,"the default keeps exact view probes enabled")
	}
	ctx.occlusion={};ctx.occlusion_adaptive_enabled=true
	for frame in 10..<12 {
		occlusion_adaptive_test_view(ctx,&w,nil,frame)
		testing.expect(t,ctx.occlusion.count==1 && !ctx.frame_stats.occlusion_probe_skipped,"two completed unhelpful probes precede backoff")
	}
	for frame in 12..<15 {
		cache:=ctx.static_meshes[front];cache.occluded=true;ctx.static_meshes[front]=cache
		occlusion_adaptive_test_view(ctx,&w,nil,frame)
		testing.expect(t,ctx.occlusion.count==0 && ctx.frame_stats.occlusion_probe_skipped && !ctx.static_meshes[front].occluded && ctx.frame_stats.occlusion_tests==0,
			"skipped work clears every previous cull and provides no light-occlusion polygons")
	}
	occlusion_adaptive_test_view(ctx,&w,nil,15)
	testing.expect(t,ctx.occlusion.count==1 && !ctx.frame_stats.occlusion_probe_skipped && ctx.frame_stats.occlusion_tests>0,"a fresh proof runs after at most three skipped moving views")
}

@(test)
occlusion_adaptive_stop_after_skip_refreshes_once_then_reuses_result :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache);ctx.occlusion_enabled=true;ctx.occlusion_adaptive_enabled=true
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	occlusion_test_cached_quad(ctx,&w,&r,-3,1.2)
	occlusion_adaptive_test_view(ctx,&w,nil,0)
	occlusion_adaptive_test_view(ctx,&w,nil,1)
	occlusion_adaptive_test_view(ctx,&w,nil,2)
	testing.expect(t,ctx.occlusion.count==0)
	occlusion_adaptive_test_view(ctx,&w,nil,2)
	testing.expect(t,ctx.occlusion.count==1 && !ctx.frame_stats.occlusion_probe_skipped && !ctx.frame_stats.occlusion_cache_reused,
		"stopping after an all-visible fallback refreshes the proof once at the new view")
	for _ in 0..<10 {
		occlusion_adaptive_test_view(ctx,&w,nil,2)
		testing.expect(t,ctx.occlusion.count==1 && ctx.frame_stats.occlusion_cache_reused && ctx.frame_stats.occlusion_tests==0,
			"the refreshed stationary view reuses its completed proof without periodic rebuilds")
	}
}

@(test)
occlusion_adaptive_useful_mesh_proofs_prevent_backoff :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache);ctx.occlusion_enabled=true;ctx.occlusion_adaptive_enabled=true
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	occlusion_test_cached_quad(ctx,&w,&r,-3,1.2)
	target:=occlusion_test_cached_quad(ctx,&w,&r,-7,0.25)
	for frame in 0..<14 {
		occlusion_adaptive_test_view(ctx,&w,nil,frame)
		testing.expect(t,ctx.occlusion.count>0 && !ctx.frame_stats.occlusion_probe_skipped && ctx.static_meshes[target].occluded,"useful mesh visibility proofs continue on every changed view")
	}
}

@(test)
occlusion_adaptive_useful_light_proofs_prevent_backoff :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache);ctx.occlusion_enabled=true;ctx.occlusion_adaptive_enabled=true
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	front:=occlusion_test_cached_quad(ctx,&w,&r,-3,1.2)
	for frame in 0..<12 {
		occlusion_adaptive_test_view(ctx,&w,nil,frame,finish=false)
		testing.expect(t,!ctx.frame_stats.occlusion_probe_skipped && !ctx.static_meshes[front].occluded,"the only mesh remains visible while local-light bounds supply the benefit")
		// cull_scene_lights uses this same conservative bounds proof before it
		// disables a native light; no graphics context is needed for the proof.
		bounds,valid:=light_influence_bounds({0,0,-7},0.25)
		assert(valid)
		testing.expect(t,bounds_occluded(bounds,&ctx.occlusion),"the wall hides the complete local-light influence")
		finish_occlusion_frame(ctx)
	}
}

@(test)
occlusion_adaptive_changes_force_fresh_pose_material_and_resolution_proofs :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache);ctx.occlusion_enabled=true;ctx.occlusion_adaptive_enabled=true
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	front:=occlusion_test_cached_quad(ctx,&w,&r,-3,1.2)
	manager:=assets.Asset_Manager{material_revision=1}
	frame:=0
	occlusion_adaptive_test_enter_skip(t,ctx,&w,&manager,&frame)
	cache:=ctx.static_meshes[front]
	cache.transform=rl.MatrixTranslate(0.1,0,0)
	cache.bounds=static_world_bounds({{-1.2,-1.2,-3},{1.2,1.2,-3}},cache.transform)
	ctx.static_meshes[front]=cache
	frame+=1;occlusion_adaptive_test_view(ctx,&w,&manager,frame)
	testing.expect(t,ctx.occlusion.count==1,"moving a blocker forces a fresh proof during backoff")
	occlusion_adaptive_test_enter_skip(t,ctx,&w,&manager,&frame)
	frame+=1;occlusion_adaptive_test_view(ctx,&w,&manager,frame,640,480)
	testing.expect(t,ctx.occlusion.count==1,"a resolution change forces a fresh proof")
	occlusion_adaptive_test_enter_skip(t,ctx,&w,&manager,&frame)
	manager.material_revision+=1
	frame+=1;occlusion_adaptive_test_view(ctx,&w,&manager,frame)
	testing.expect(t,ctx.occlusion.count==1,"material edits force a fresh proof")
	occlusion_adaptive_test_enter_skip(t,ctx,&w,&manager,&frame)
	assert(ecs.set_static_mesh_opacity(&w,front,0.5))
	frame+=1;occlusion_adaptive_test_view(ctx,&w,&manager,frame)
	testing.expect(t,ctx.frame_stats.occlusion_tests>0 && !ctx.static_meshes[front].occlusion_opaque && !ctx.static_meshes[front].occluded,
		"changing opacity immediately reclassifies the blocker and clears hidden flags")
	assert(ecs.set_static_mesh_opacity(&w,front,1))
	frame+=1;occlusion_adaptive_test_view(ctx,&w,&manager,frame)
	testing.expect(t,ctx.occlusion.count==1,"restoring opacity refreshes the real opaque face")
}
