package main

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

main :: proc() {
	// Projection must retain two dimensions on walls and a consistent tangent
	// frame on opposite faces; otherwise normal maps invert or smear vertically.
	for n in ([6][3]f32{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) {
		uv,t:=bridge.static_mesh_projection({4,8,12},n)
		tangent:=[3]f32{t[0],t[1],t[2]}
		bitangent:=linalg.cross(n,tangent)*t[3]
		u2,_:=bridge.static_mesh_projection([3]f32{4,8,12}+tangent*4,n)
		v2,_:=bridge.static_mesh_projection([3]f32{4,8,12}+bitangent*4,n)
		assert(u2-uv==[2]f32{1,0} && v2-uv==[2]f32{0,1})
	}
	for arg in os.args[1:] {if arg=="--runtime" {validate_runtime()}}
	fmt.println("Static mesh material validation passed")
}

sample :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager) -> rl.Color {
	for _ in 0..<3 {
		rl.BeginDrawing(); assert(bridge.draw_scene_ex(ctx,w,manager,{background_color=rl.BLACK})); rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen(); defer rl.UnloadImage(image)
	return rl.GetImageColor(image,160,120)
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN}); rl.InitWindow(320,240,"Static mesh material validation"); defer rl.CloseWindow()
	ctx,ok:=bridge.init("build",320,240); assert(ok); defer bridge.shutdown(&ctx)
	manager:=assets.init("build"); defer assets.shutdown(&manager)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	validate_camera_projection(&ctx,&registry,&manager)
	validate_instanced_shadows(&ctx,&registry,&manager)
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,camera,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&w,&registry,camera,ecs.Camera3D{active=true,target={0,0,-1},up={0,1,0},fovy=60}))
	volume:=geometry.Volume{size={1,1,1},spacing=2,origin={-1,-1,-6},cells=make([]u8,1)}
	defer delete(volume.cells)
	volume.cells[0]=1
	colors:=[2][4]u8{{},{255,255,255,255}}
	mesh,valid:=geometry.surface(volume,colors[:]); assert(valid); defer geometry.destroy_mesh(&mesh)
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,entity,ecs.Transform{scale={1,1,1}}))
	assert(ecs.set_static_mesh(&w,entity,mesh))
	path :: "static-runtime.material.json"
	full_path :: "build/static-runtime.material.json"
	defer os.remove(full_path)
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[220,40,20,255]}`)==nil)
	renderer:=ecs.MeshRenderer{primitive="static",material=path,color={255,255,255,255},shadows=false}
	assert(ecs.add(&w,&registry,entity,renderer))
	red:=sample(&ctx,&w,&manager)
	assert(red.r>red.g*2 && red.r>red.b*2,"runtime mesh must use its material without a duplicate primitive")
	assert(len(ctx.static_meshes)==1 && len(ctx.r3d_materials)==1)
	// As with primitive renderers, color supplies the fallback when no material
	// is selected. This must work without replacing installed geometry.
	ambient:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=1}))
	renderer.material=""; renderer.color={20,220,20,255}; assert(ecs.set(&w,entity,renderer))
	green:=sample(&ctx,&w,&manager)
	assert(int(green.g)>int(green.r)*2 && int(green.g)>int(green.b)*2,"renderer fallback color must style the mesh")
	// A material reload also reuses the installed mesh and material cache entry.
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[20,40,220,255]}`)==nil)
	stale:=manager.materials[path]; stale.modified_time=-2; manager.materials[path]=stale
	assets.refresh_materials(&manager)
	renderer.material=path; renderer.color={255,255,255,255}; assert(ecs.set(&w,entity,renderer))
	blue:=sample(&ctx,&w,&manager)
	assert(blue.b>blue.r*2 && blue.b>blue.g*2,"static mesh material reload must update pixels")
	assert(len(ctx.static_meshes)==1 && len(ctx.r3d_materials)==1)
	hit,found:=ecs.physics_3d_raycast(&w,{0,0,0},{0,0,-10})
	assert(found && hit.entity==entity,"material styling must preserve static collision")
	validate_static_submission(&ctx,&w,&registry,&manager,mesh,entity)
	assert(ecs.set_enabled(&w,entity,false)); assert(sample(&ctx,&w,&manager).r<5)
	assert(ecs.destroy_entity(&w,entity)); sample(&ctx,&w,&manager)
	assert(len(ctx.static_meshes)==0,"entity destruction must release the GPU mesh")
	assert(len(manager.diagnostics.reported)==0)
	validate_static_shadow_pixels(&ctx,&registry,&manager)
	validate_occlusion(&ctx,&registry,&manager)
	validate_occluded_shadow(&ctx,&registry,&manager)
	validate_light_occlusion(&ctx,&registry,&manager)
	validate_render_cache(&ctx,&registry,&manager)
	validate_instancing(&ctx,&registry,&manager)
	validate_instanced_shadows(&ctx,&registry,&manager)
}

validate_static_shadow_pixels :: proc(ctx:^bridge.Context,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,camera,ecs.Transform{position={0,3,0},scale={1,1,1}}))
	assert(ecs.add(&w,registry,camera,ecs.Camera3D{active=true,target={0,0,-5},up={0,1,0},fovy=50}))
	ambient:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=0.1}))
	light:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,light,ecs.DirectionalLight{direction={-1,-1,0},color={255,255,255,255},intensity=1,range=16,shadows=true,shadow_opacity=1,shadow_overrides={update_mode="continuous"}}))
	volume:=geometry.Volume{size={1,1,1},spacing=1,origin={-0.5,0,-0.5},cells=make([]u8,1)}
	defer delete(volume.cells); volume.cells[0]=1
	colors:=[2][4]u8{{},{255,255,255,255}}
	mesh,valid:=geometry.surface(volume,colors[:]); assert(valid); defer geometry.destroy_mesh(&mesh)
	floor:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,floor,ecs.Transform{position={0,-0.1,-5},scale={20,0.1,20}}))
	assert(ecs.set_static_mesh(&w,floor,mesh,collidable=false))
	caster:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,caster,ecs.Transform{position={5,1,-5},scale={1,2,1}}))
	assert(ecs.set_static_mesh(&w,caster,mesh,collidable=false))
	ctx.static_optimizations_disabled=true; sample(ctx,&w,manager)
	baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(baseline)
	before:=rl.LoadImageColors(baseline); defer rl.UnloadImageColors(before)
	ctx.static_optimizations_disabled=false; sample(ctx,&w,manager)
	assert(ctx.frame_stats.static_clusters_outside_view==1 && ctx.frame_stats.static_submitted==2,"the camera-hidden caster must reach the shadow pass")
	optimized:=rl.LoadImageFromScreen(); defer rl.UnloadImage(optimized)
	after:=rl.LoadImageColors(optimized); defer rl.UnloadImageColors(after)
	for i in 0..<int(baseline.width*baseline.height) {assert(before[i]==after[i],"cluster culling must preserve off-screen shadows pixel for pixel")}
	assert(ecs.set_enabled(&w,caster,false)); sample(ctx,&w,manager)
	unshadowed:=rl.LoadImageFromScreen(); defer rl.UnloadImage(unshadowed)
	without:=rl.LoadImageColors(unshadowed); defer rl.UnloadImageColors(without)
	changed:=0
	for i in 0..<int(baseline.width*baseline.height) {if before[i]!=without[i] {changed+=1}}
	assert(changed>20,"the off-screen fixture must cast a visible shadow")
	// Manual maps must hold their previous contents until explicitly requested.
	// Previously, toggling light activation every draw bypassed this mode.
	directional,_:=ecs.get_directional_light(&w,light)
	directional.shadow_overrides.update_mode="manual"; assert(ecs.set(&w,light,directional))
	assert(ecs.set_enabled(&w,caster,true)); sample(ctx,&w,manager)
	manual:=rl.LoadImageFromScreen(); defer rl.UnloadImage(manual)
	assert(ecs.set_enabled(&w,caster,false)); sample(ctx,&w,manager)
	held:=rl.LoadImageFromScreen(); defer rl.UnloadImage(held)
	assert_same_occlusion_pixels(manual,held)
	assert(bridge.request_shadow_update(ctx,light)); sample(ctx,&w,manager)
	refreshed:=rl.LoadImageFromScreen(); defer rl.UnloadImage(refreshed)
	assert_same_occlusion_pixels(unshadowed,refreshed)
	fmt.println("PASS static cache, camera culling, identical pixels, and off-screen shadows")
}

validate_static_submission :: proc(ctx:^bridge.Context,w:^ecs.World,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager,mesh:geometry.Mesh,visible:ecs.Entity) {
	parent:=ecs.create_entity(w)
	assert(ecs.add(w,registry,parent,ecs.Transform{position={100,0,0},scale={1,1,1}}))
	defer ecs.destroy_entity(w,parent)
	for _ in 0..<4 {
		e:=ecs.create_entity(w); assert(ecs.set_parent(w,e,parent))
		assert(ecs.add(w,registry,e,ecs.Transform{scale={1,1,1}}))
		assert(ecs.add(w,registry,e,ecs.MeshRenderer{primitive="static",color={255,255,255,255},shadows=false}))
		assert(ecs.set_static_mesh(w,e,mesh,collidable=false))
	}
	assert(ecs.set_transform(w,visible,ecs.Transform{rotation={12,7,4},scale={1.1,1.2,1}}))
	ctx.static_optimizations_disabled=true
	sample(ctx,w,manager)
	assert(ctx.frame_stats.static_submitted==5)
	baseline:=rl.LoadImageFromScreen(); defer rl.UnloadImage(baseline)
	before:=rl.LoadImageColors(baseline); defer rl.UnloadImageColors(before)
	ctx.static_optimizations_disabled=false
	sample(ctx,w,manager)
	assert(ctx.frame_stats.static_submitted==1 && ctx.frame_stats.static_meshes_skipped==4,"reject camera-hidden non-casters before submission")
	assert(ctx.frame_stats.static_clusters==2 && ctx.frame_stats.static_clusters_outside_view==1)
	assert(ctx.frame_stats.static_bounds_rebuilt==0 && ctx.frame_stats.static_uploads==0,"stable frames reuse GPU data, matrices, and bounds")
	optimized:=rl.LoadImageFromScreen(); defer rl.UnloadImage(optimized)
	after:=rl.LoadImageColors(optimized); defer rl.UnloadImageColors(after)
	for i in 0..<int(baseline.width*baseline.height) {assert(before[i]==after[i],"optimized and baseline frames must have identical pixels")}
	// Off-camera shadow casters must still reach R3D's shadow-frustum tests.
	for e in ecs.child_entities(w,parent) {
		renderer,_:=ecs.get_mesh_renderer(w,e); renderer.shadows=true; assert(ecs.set(w,e,renderer))
	}
	sample(ctx,w,manager)
	assert(ctx.frame_stats.static_submitted==5 && ctx.frame_stats.static_meshes_skipped==0)
	ctx.shadows_disabled=true; sample(ctx,w,manager)
	assert(ctx.frame_stats.static_submitted==1 && ctx.frame_stats.static_meshes_skipped==4)
	ctx.shadows_disabled=false
	// A moved parent must restore visibility on the next draw without uploads.
	assert(ecs.set_transform(w,parent,ecs.Transform{scale={1,1,1}})); sample(ctx,w,manager)
	assert(ctx.frame_stats.static_submitted==5 && ctx.frame_stats.static_clusters_outside_view==0)
	assert(ecs.set_enabled(w,parent,false)); sample(ctx,w,manager)
	assert(ctx.frame_stats.static_enabled==1 && ctx.frame_stats.static_submitted==1)
	assert(ecs.set_enabled(w,parent,true))
	// Mesh replacement invalidates local bounds even at an unchanged transform.
	assert(ecs.set_static_mesh(w,visible,mesh)); sample(ctx,w,manager)
	assert(ctx.static_meshes[visible].pose_cached && ctx.static_meshes[visible].revision==w.static_meshes[visible].revision)
}
