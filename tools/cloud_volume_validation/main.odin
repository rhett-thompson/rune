package main

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:math"
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
	assert(v.detail_offset==([3]f32{}) && v.detail_strength==0.28,"legacy JSON keeps the original fine noise defaults")
	for text in ([]string{`null`,`{"steps":7}`,`{"steps":97}`,`{"steps":32.5}`,`{"density":-1}`,`{"noise_scale":0}`,`{"coverage":1.1}`,`{"coverage":null}`,`{"color":[256,0,0,255]}`,`{"noise_offset":[0,0]}`,`{"detail_offset":[0,0]}`,`{"detail_offset":[0,true,0]}`,`{"detail_offset":[0,1e100,0]}`,`{"detail_offset":null}`,`{"detail_strength":-0.1}`,`{"detail_strength":1.1}`,`{"detail_strength":null}`,`{"detail_strength":true}`,`{"unknown":true}`}) {
		_,valid:=ecs.cloud_volume_from_json(parse(text)); assert(!valid,text)
	}
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	entity:=ecs.create_entity(&w)
	assert(ecs.add_component(&w,&registry,entity,"CloudVolume",parse(`{"coverage":0.7,"steps":48,"detail_offset":[11,-7,2.5],"detail_strength":0.4}`)))
	v,ok=ecs.get(&w,entity,ecs.CloudVolume)
	assert(ok && v.coverage==0.7 && v.steps==48 && v.density==0.035)
	invalid:=v; invalid.steps=0
	assert(!ecs.set(&w,entity,invalid))
	unchanged,_:=ecs.get(&w,entity,ecs.CloudVolume); assert(unchanged==v)
	for bad in ([5]f32{-0.1,1.1,math.nan_f32(),math.inf_f32(1),math.inf_f32(-1)}) {
		invalid=v; invalid.detail_strength=bad; assert(!ecs.set(&w,entity,invalid))
		unchanged,_=ecs.get(&w,entity,ecs.CloudVolume); assert(unchanged==v)
	}
	invalid=v; invalid.detail_offset.y=math.nan_f32(); assert(!ecs.set(&w,entity,invalid))
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
	validate_fine_noise_motion(&ctx,&w,&manager,&registry,camera)
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

Cloud_Motion_Validation :: struct {
	width,height,steps,ray_noise_samples,probe_noise_samples: int,
	changed_pixels,repeat_max_difference,period_max_difference,disabled_max_difference: int,
	mean_evolution_difference,max_frame_mean_difference: f64,
	max_frame_pixel_difference: int,
	foreground_r,embedded_r,inside_r: u8,
}

cloud_motion_capture :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,path:cstring=nil) -> []rl.Color {
	for _ in 0..<3 {
		rl.BeginDrawing(); assert(bridge.draw_scene_ex(ctx,w,manager,{background_color=rl.BLACK})); rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen(); defer rl.UnloadImage(image)
	if path!=nil {assert(rl.ExportImage(image,path))}
	colors:=rl.LoadImageColors(image); defer rl.UnloadImageColors(colors)
	result:=make([]rl.Color,int(image.width*image.height))
	copy(result,colors[:len(result)])
	return result
}

cloud_motion_difference :: proc(a,b:[]rl.Color) -> (mean:f64,maximum,changed:int) {
	assert(len(a)==len(b))
	for before,i in a {
		after:=b[i]
		delta:=max(abs(int(before.r)-int(after.r)),abs(int(before.g)-int(after.g)),abs(int(before.b)-int(after.b)))
		mean+=f64(delta); maximum=max(maximum,delta)
		if delta>2 {changed+=1}
	}
	return mean/f64(len(a)),maximum,changed
}

// Move only the fine octave: translating a proxy, moving the camera, or varying
// coverage cannot satisfy this test. Screen-space march jitter stays fixed.
validate_fine_noise_motion :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,
	registry:^ecs.Component_Registry,camera:ecs.Entity) {
	assert(ecs.set_transform(w,camera,ecs.Transform{scale={1,1,1}}))
	cam,_:=ecs.get_camera_3d(w,camera); cam.target={0,0,-1}; assert(ecs.set_camera_3d(w,camera,cam))
	cloud:=ecs.create_entity(w); defer ecs.destroy_entity(w,cloud)
	pose:=ecs.Transform{position={0,0,-100},scale={220,110,160}}
	assert(ecs.add(w,registry,cloud,pose))
	v:=ecs.default_cloud_volume(); v.color={255,255,255,255}; v.shadow_color=v.color
	v.density=0.055; v.noise_scale=85; v.coverage=0.6; v.steps=24; v.noise_offset={7,13,19}
	assert(ecs.add(w,registry,cloud,v))
	baseline:=cloud_motion_capture(ctx,w,manager,"build/cloud-motion-phase-a.png"); defer delete(baseline)
	v.detail_offset={25,11,-17}; assert(ecs.set(w,cloud,v))
	evolved:=cloud_motion_capture(ctx,w,manager,"build/cloud-motion-phase-b.png"); defer delete(evolved)
	report:=Cloud_Motion_Validation{width=320,height=240,steps=int(v.steps),ray_noise_samples=2,probe_noise_samples=1}
	report.mean_evolution_difference,_,report.changed_pixels=cloud_motion_difference(baseline,evolved)
	assert(report.mean_evolution_difference>0.5 && report.changed_pixels>500,
		"independent fine noise must visibly evolve density at fixed transform and broad phase")
	unchanged_pose,_:=ecs.get_transform(w,cloud); assert(unchanged_pose==pose)
	v.detail_offset={}; assert(ecs.set(w,cloud,v))
	repeated:=cloud_motion_capture(ctx,w,manager,"build/cloud-motion-repeat.png"); defer delete(repeated)
	_,report.repeat_max_difference,_=cloud_motion_difference(baseline,repeated)
	assert(report.repeat_max_difference==0,"restoring the same density phases produces an identical frame")
	// One fine phase period is noise_scale because detail_offset enters after
	// the 2.07 frequency multiplier. Crossing it must not create an atlas seam.
	v.detail_offset={v.noise_scale,0,0}; assert(ecs.set(w,cloud,v))
	periodic:=cloud_motion_capture(ctx,w,manager); defer delete(periodic)
	_,report.period_max_difference,_=cloud_motion_difference(baseline,periodic)
	assert(report.period_max_difference<=1,"wrapped fine phase remains continuous across the tile period")
	v.detail_offset={}; assert(ecs.set(w,cloud,v))
	previous:=cloud_motion_capture(ctx,w,manager)
	for frame in 1..=12 {
		v.detail_offset=[3]f32{0.05,-0.02,0.025}*f32(frame); assert(ecs.set(w,cloud,v))
		next:=cloud_motion_capture(ctx,w,manager)
		mean,maximum,_:=cloud_motion_difference(previous,next)
		report.max_frame_mean_difference=max(report.max_frame_mean_difference,mean)
		report.max_frame_pixel_difference=max(report.max_frame_pixel_difference,maximum)
		delete(previous); previous=next
	}
	delete(previous)
	assert(report.max_frame_mean_difference<1 && report.max_frame_pixel_difference<20,
		"small continuous phase steps cannot produce density popping or changing random grain")
	v.detail_strength=0; v.detail_offset={}; assert(ecs.set(w,cloud,v))
	coarse:=cloud_motion_capture(ctx,w,manager); defer delete(coarse)
	v.detail_offset={25,11,-17}; assert(ecs.set(w,cloud,v))
	coarse_shifted:=cloud_motion_capture(ctx,w,manager); defer delete(coarse_shifted)
	_,report.disabled_max_difference,_=cloud_motion_difference(coarse,coarse_shifted)
	assert(report.disabled_max_difference==0,"zero fine contribution ignores independent phase")
	// Animated clouds retain opaque clipping and visibility inside the proxy.
	v.detail_strength=0.4; assert(ecs.set(w,cloud,v))
	blocker:=ecs.create_entity(w); defer ecs.destroy_entity(w,blocker)
	assert(ecs.add(w,registry,blocker,ecs.Transform{position={0,0,-10},scale={100,100,1}}))
	assert(ecs.add(w,registry,blocker,ecs.MeshRenderer{primitive="cube",color={0,0,0,255}}))
	report.foreground_r=center_pixel(ctx,w,manager).r
	assert(report.foreground_r<5,"opaque foreground still occludes an independently evolving volume")
	assert(ecs.set_transform(w,blocker,ecs.Transform{position={0,0,-100},scale={100,100,1}}))
	report.embedded_r=center_pixel(ctx,w,manager).r
	assert(report.embedded_r>20,"evolving density in front of an embedded solid remains visible")
	assert(ecs.set_enabled(w,blocker,false))
	assert(ecs.set_transform(w,camera,ecs.Transform{position={0,0,-100},scale={1,1,1}}))
	cam.target={0,0,-101}; assert(ecs.set_camera_3d(w,camera,cam))
	report.inside_r=center_pixel(ctx,w,manager).r
	assert(report.inside_r>20,"fine phase also evolves density around a camera inside the cloud")
	bytes,err:=json.marshal(report,allocator=context.temp_allocator); assert(err==nil)
	assert(os.write_entire_file("build/cloud-motion-validation.json",bytes)==nil)
	fmt.println("Cloud fine-noise motion",report)
}
