package main

import "core:fmt"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

validate_light_occlusion :: proc(ctx:^bridge.Context,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	w:=ecs.init(); defer ecs.destroy(&w)
	defer {ctx.occlusion_enabled=false; ctx.static_optimizations_disabled=false}
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,camera,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&w,registry,camera,ecs.Camera3D{active=true,target={0,0,-1},up={0,1,0},fovy=60}))
	ambient:=ecs.create_entity(&w); assert(ecs.add(&w,registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=0.1}))
	directional:=ecs.create_entity(&w); assert(ecs.add(&w,registry,directional,ecs.DirectionalLight{direction={0,-1,0},color={255,255,255,255},intensity=0.1,range=20}))
	volume:=geometry.Volume{size={1,1,1},spacing=1,origin={-0.5,0,-0.5},cells=make([]u8,1)}
	defer delete(volume.cells); volume.cells[0]=1
	colors:=[2][4]u8{{},{255,255,255,255}}
	mesh,valid:=geometry.surface(volume,colors[:]); assert(valid); defer geometry.destroy_mesh(&mesh)
	wall:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,wall,ecs.Transform{position={0,-2,-3},scale={4,4,0.1}}))
	assert(ecs.set_static_mesh(&w,wall,mesh,collidable=false))
	floor:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,floor,ecs.Transform{position={0,-2.1,-6},scale={12,0.1,12}}))
	assert(ecs.set_static_mesh(&w,floor,mesh,collidable=false))
	point:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,point,ecs.Transform{position={0,0,-7},scale={1,1,1}}))
	assert(ecs.add(&w,registry,point,ecs.PointLight{color={255,255,255,255},intensity=1,range=0.5,shadows=true,shadow_opacity=1,shadow_overrides={update_mode="manual"}}))
	spot:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,spot,ecs.Transform{position={0,0,-7},scale={1,1,1}}))
	assert(ecs.add(&w,registry,spot,ecs.SpotLight{direction={0,0,-1},color={255,255,255,255},intensity=1,range=0.5,inner_angle=20,outer_angle=35}))
	baseline:=occlusion_frame(ctx,&w,manager,false); defer rl.UnloadImage(baseline)
	optimized:=occlusion_frame(ctx,&w,manager,true); defer rl.UnloadImage(optimized)
	assert_same_occlusion_pixels(baseline,optimized)
	assert(ctx.frame_stats.local_lights==2 && ctx.frame_stats.local_lights_occluded==2 && ctx.frame_stats.local_shadow_lights_occluded==1)
	assert(!r3d.IsLightEnabled(ctx.scene_lights[point]) && !r3d.IsLightEnabled(ctx.scene_lights[spot]))
	assert(r3d.IsLightEnabled(ctx.scene_lights[directional]),"directional lighting remains active")
	// The source remains hidden, but its enlarged volume reaches visible floor.
	light,_:=ecs.get_point_light(&w,point); light.range=8; assert(ecs.set(&w,point,light))
	wide_baseline:=occlusion_frame(ctx,&w,manager,false); defer rl.UnloadImage(wide_baseline)
	wide_optimized:=occlusion_frame(ctx,&w,manager,true); defer rl.UnloadImage(wide_optimized)
	assert(ctx.frame_stats.local_lights_occluded==1 && r3d.IsLightEnabled(ctx.scene_lights[point]),"hidden sources must retain lighting when their volume is visible")
	assert_same_occlusion_pixels(wide_baseline,wide_optimized)
	// Verify that keeping the hidden source preserves actual visible lighting.
	light.intensity=0; assert(ecs.set(&w,point,light)); sample(ctx,&w,manager)
	without:=rl.LoadImageFromScreen(); defer rl.UnloadImage(without)
	a:=rl.LoadImageColors(wide_optimized); defer rl.UnloadImageColors(a)
	b:=rl.LoadImageColors(without); defer rl.UnloadImageColors(b)
	changed:=0; for i in 0..<int(without.width*without.height) {if a[i]!=b[i] {changed+=1}}
	assert(changed>20,"the hidden point source must illuminate visible floor outside the wall")
	light.intensity=1; light.range=0.5; assert(ecs.set(&w,point,light))
	// Removing the wall restores both lights, including the manual shadow map.
	assert(ecs.set_enabled(&w,wall,false)); sample(ctx,&w,manager)
	assert(ctx.frame_stats.local_lights_occluded==0 && r3d.IsLightEnabled(ctx.scene_lights[point]) && r3d.IsLightEnabled(ctx.scene_lights[spot]))
	assert(ecs.set_enabled(&w,wall,true)); sample(ctx,&w,manager)
	assert(ctx.frame_stats.local_lights_occluded==2)
	// Current position/range must be tested before R3D refreshes its cached AABB.
	assert(ecs.set_transform(&w,point,ecs.Transform{position={4,0,-7},scale={1,1,1}})); sample(ctx,&w,manager)
	assert(ctx.frame_stats.local_lights_occluded==1 && r3d.IsLightEnabled(ctx.scene_lights[point]))
	ctx.static_optimizations_disabled=true; sample(ctx,&w,manager)
	assert(ctx.frame_stats.local_lights_occluded==0 && r3d.IsLightEnabled(ctx.scene_lights[spot]),"baseline switch must restore local lights")
	assert(ctx.frame_stats.light_properties_updated==0,"unchanged light properties do not dirty native matrices")
	light.color={80,120,200,255}; light.intensity=0.4; light.specular=0.75; assert(ecs.set(&w,point,light))
	rl.BeginDrawing(); assert(bridge.draw_scene_ex(ctx,&w,manager,{background_color=rl.BLACK})); rl.EndDrawing()
	assert(ctx.frame_stats.light_properties_updated==3)
	id:=ctx.scene_lights[point]
	assert(r3d.GetLightEnergy(id)==light.intensity && r3d.GetLightSpecular(id)==light.specular && r3d.GetLightColor(id)==rl.Color{80,120,200,255})
	assert(ecs.set_enabled(&w,point,false)); sample(ctx,&w,manager); assert(!r3d.IsLightEnabled(id))
	assert(ecs.set_enabled(&w,point,true)); sample(ctx,&w,manager); assert(r3d.IsLightEnabled(id) && ctx.frame_stats.light_properties_updated==0)
	ctx.render_optimizations_disabled=true; sample(ctx,&w,manager)
	assert(ctx.frame_stats.light_properties_updated==18,"baseline updates all six properties on each of three lights")
	ctx.render_optimizations_disabled=false
	fmt.println("PASS light volume occlusion, hidden-source visible illumination, live edits, and baseline pixels")
}
