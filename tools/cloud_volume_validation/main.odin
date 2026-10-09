package main

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

parse :: proc(text:string) -> json.Value {
	v:json.Value
	assert(json.unmarshal(transmute([]u8)text,&v,allocator=context.temp_allocator)==nil)
	return v
}

main :: proc() {
	v,ok:=ecs.cloud_volume_from_json(parse(`{}`))
	assert(ok && v==ecs.default_cloud_volume())
	for text in ([]string{`null`,`{"steps":7}`,`{"steps":97}`,`{"steps":32.5}`,`{"density":-1}`,`{"noise_scale":0}`,`{"coverage":1.1}`,`{"coverage":null}`,`{"color":[256,0,0,255]}`,`{"noise_offset":[0,0]}`,`{"unknown":true}`}) {
		_,valid:=ecs.cloud_volume_from_json(parse(text)); assert(!valid,text)
	}
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	entity:=ecs.create_entity(&w)
	assert(ecs.add_component(&w,&registry,entity,"CloudVolume",parse(`{"coverage":0.7,"steps":48}`)))
	v,ok=ecs.get(&w,entity,ecs.CloudVolume)
	assert(ok && v.coverage==0.7 && v.steps==48 && v.density==0.035)
	invalid:=v; invalid.steps=0
	assert(!ecs.set(&w,entity,invalid))
	unchanged,_:=ecs.get(&w,entity,ecs.CloudVolume); assert(unchanged==v)
	snapshot,found:=ecs.get_component(&w,entity,"CloudVolume"); assert(found)
	roundtrip,valid:=ecs.cloud_volume_from_json(snapshot); assert(valid && roundtrip==v)
	for arg in os.args[1:] {if arg=="--runtime" {validate_runtime()}}
	fmt.println("Cloud volume validation passed")
}

frame_pixels :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,path:cstring=nil) -> [2]rl.Color {
	for _ in 0..<3 {
		rl.BeginDrawing()
		assert(bridge.draw_scene_ex(ctx,w,manager,{background_color=rl.BLACK}))
		rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen(); defer rl.UnloadImage(image)
	if path!=nil {assert(rl.ExportImage(image,path))}
	return {rl.GetImageColor(image,160,120),rl.GetImageColor(image,10,120)}
}

center_pixel :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager) -> rl.Color {
	return frame_pixels(ctx,w,manager)[0]
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,240,"Cloud volume validation"); defer rl.CloseWindow()
	ctx,ok:=bridge.init(".",320,240); assert(ok); defer bridge.shutdown(&ctx)
	manager:=assets.init("."); defer assets.shutdown(&manager)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add_component(&w,&registry,camera,"Transform",parse(`{"position":[0,0,0]}`)))
	assert(ecs.add_component(&w,&registry,camera,"Camera3D",parse(`{"active":true,"target":[0,0,-1],"fovy":60}`)))
	cloud:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,cloud,ecs.Transform{position={0,0,-6},scale={4,3,4}}))
	v:=ecs.default_cloud_volume(); v.color={255,255,255,255}; v.shadow_color=v.color; v.density=1; v.coverage=1
	assert(ecs.add(&w,&registry,cloud,v))
	p:=center_pixel(&ctx,&w,&manager); fmt.println("unobstructed",p)
	assert(p.r>150,"ray marching must produce opacity inside the ellipsoid")
	blocker:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,blocker,ecs.Transform{position={0,0,-2},scale={3,3,0.2}}))
	assert(ecs.add(&w,&registry,blocker,ecs.MeshRenderer{primitive="cube",color={0,0,0,255}}))
	p=center_pixel(&ctx,&w,&manager); fmt.println("foreground",p)
	assert(p.r<5,"opaque foreground must completely occlude clouds")
	assert(ecs.set_transform(&w,blocker,ecs.Transform{position={0,0,-6},scale={3,3,0.2}}))
	p=center_pixel(&ctx,&w,&manager); fmt.println("embedded",p)
	assert(p.r>80,"clouds in front of an embedded opaque object must remain visible")
	ecs.destroy_entity(&w,blocker)
	assert(ecs.set_transform(&w,camera,ecs.Transform{position={0,0,-6},scale={1,1,1}}))
	cam,_:=ecs.get_camera_3d(&w,camera); cam.target={0,0,-7}; assert(ecs.set_camera_3d(&w,camera,cam))
	p=center_pixel(&ctx,&w,&manager); fmt.println("inside",p)
	assert(p.r>80,"camera inside a volume must see participating medium")
	v.density=0; assert(ecs.set(&w,cloud,v))
	assert(center_pixel(&ctx,&w,&manager).r<5,"zero density must render empty space")
	assert(ecs.remove_component(&w,cloud,"CloudVolume"))
	_ = center_pixel(&ctx,&w,&manager)
	assert(len(ctx.cloud_volumes.aliases)==0,"removing a volume must release its shader alias")
	validate_height_fog(&ctx,&w,&manager,&registry,camera)
	assert(len(manager.diagnostics.reported)==0)
}

validate_height_fog :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,
	registry:^ecs.Component_Registry,camera:ecs.Entity) {
	assert(ecs.set_transform(w,camera,ecs.Transform{scale={1,1,1}}))
	cam,_:=ecs.get_camera_3d(w,camera); cam.target={0,0,-1}; assert(ecs.set_camera_3d(w,camera,cam))
	cloud:=ecs.create_entity(w); defer ecs.destroy_entity(w,cloud)
	assert(ecs.add(w,registry,cloud,ecs.Transform{position={0,0,-6},scale={4,3,4}}))
	v:=ecs.default_cloud_volume(); v.color={255,255,255,255}; v.shadow_color=v.color; v.density=1; v.coverage=1
	assert(ecs.add(w,registry,cloud,v))
	clear:=center_pixel(ctx,w,manager)
	post:=ecs.create_entity(w); defer ecs.destroy_entity(w,post)
	profile:=ecs.default_post_processing()
	profile.height_fog={enabled=true,color={0,0,255,255},density=0.03,falloff=0,sky_distance=1000}
	assert(ecs.add(w,registry,post,profile))
	pixels:=frame_pixels(ctx,w,manager,"build/cloud-height-fog-validation.png")
	fmt.println("height fog near cloud / empty sky",pixels)
	assert(pixels[1].b>200 && pixels[1].r<15,"empty sky must retain full distant height fog")
	assert(pixels[0].r>180 && pixels[0].r<clear.r,
		"nearby cloud receives only fog before its visible density, not the full sky column")
	// Moving an opaque surface behind a dense cloud must not choose a new fog
	// distance for the already-opaque participating medium in front of it.
	blocker:=ecs.create_entity(w)
	assert(ecs.add(w,registry,blocker,ecs.Transform{position={0,0,-12},scale={3,3,0.2}}))
	assert(ecs.add(w,registry,blocker,ecs.MeshRenderer{primitive="cube",color={0,0,0,255}}))
	near_background:=center_pixel(ctx,w,manager)
	assert(ecs.set_transform(w,blocker,ecs.Transform{position={0,0,-120},scale={30,30,0.2}}))
	far_background:=center_pixel(ctx,w,manager)
	fmt.println("height fog near / far opaque background",near_background,far_background)
	assert(abs(i32(near_background.r)-i32(far_background.r))<8 && far_background.r>180,
		"fog behind an opaque cloud cannot wash out its foreground radiance")
	assert(ecs.set_transform(w,blocker,ecs.Transform{position={0,0,-2},scale={3,3,0.2}}))
	foreground:=center_pixel(ctx,w,manager); fmt.println("height fog foreground",foreground)
	assert(foreground.r<5 && foreground.b>25 && foreground.b<100,
		"foreground solids still occlude clouds and receive their own short fog column")
	assert(ecs.destroy_entity(w,blocker))
	assert(ecs.set_transform(w,camera,ecs.Transform{position={0,0,-6},scale={1,1,1}}))
	cam.target={0,0,-7}; assert(ecs.set_camera_3d(w,camera,cam))
	inside:=center_pixel(ctx,w,manager); fmt.println("height fog inside cloud",inside)
	assert(inside.r>180,"a camera inside a cloud must not receive distant sky fog over near density")
	assert(ecs.set_transform(w,camera,ecs.Transform{scale={1,1,1}}))
	cam.target={0,0,-1}; assert(ecs.set_camera_3d(w,camera,cam))
	profile.height_fog.enabled=false
	profile.upper_height_fog=profile.height_fog; profile.upper_height_fog.enabled=true
	assert(ecs.set(w,post,profile))
	upper:=center_pixel(ctx,w,manager); fmt.println("upper height fog near cloud",upper)
	assert(upper.r>180 && upper.r<clear.r,"the upper fog layer respects cloud depth too")
	profile.height_fog.enabled=true; assert(ecs.set(w,post,profile))
	both:=center_pixel(ctx,w,manager); fmt.println("both height fog layers near cloud",both)
	assert(both.r>150 && both.r<upper.r,"both fog layers attenuate nearby clouds by the finite foreground path")
}
