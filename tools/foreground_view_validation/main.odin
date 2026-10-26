package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

CAMERA :: rl.Camera3D{position={},target={0,0,-1},up={0,1,0},fovy=60,projection=.PERSPECTIVE}

Geometry :: struct {
	mesh: r3d.Mesh,
	contact, missing: bool,
	emission: f32,
}

// Submit the same ordinary deferred materials used by a regular native view.
draw_geometry :: proc(ctx:^bridge.Context,data: rawptr) {
	s:=cast(^Geometry)data
	if s.missing {return}
	material:=r3d.MATERIAL_BASE
	material.albedo.color={190,190,190,255}
	r3d.DrawMeshEx(s.mesh,material,{0,0,-1},rl.Quaternion(1),{0.8,0.8,0.05})
	if s.contact {
		r3d.DrawMeshEx(s.mesh,material,{0,0,-0.88},rl.Quaternion(1),{0.24,0.24,0.18})
	}
	// A separate self-lit surface exercises regular R3D emission materials.
	emitter:=r3d.MATERIAL_BASE
	emitter.albedo.color={0,0,0,255}
	emitter.emission.color={30,160,220,255}
	emitter.emission.energy=s.emission
	r3d.DrawMeshEx(s.mesh,emitter,{0.49,-0.2,-0.94},rl.Quaternion(1),{0.025,0.13,0.025})
}

pixel_at :: proc(image: rl.Image, camera: rl.Camera3D, point: rl.Vector3) -> rl.Color {
	p:=rl.GetWorldToScreenEx(point,camera,image.width,image.height)
	return rl.GetImageColor(image,clamp(i32(p.x),0,image.width-1),clamp(i32(p.y),0,image.height-1))
}

radiance_at :: proc(image:rl.Image,camera:rl.Camera3D,point:rl.Vector3) -> f32 {
	assert(image.format==.UNCOMPRESSED_R16G16B16A16)
	p:=rl.GetWorldToScreenEx(point,camera,image.width,image.height)
	x,y:=clamp(i32(p.x),0,image.width-1),clamp(i32(p.y),0,image.height-1)
	values:=cast([^]f16)image.data
	i:=int((y*image.width+x)*4)
	return max(f32(values[i]),f32(values[i+1]),f32(values[i+2]))
}

patch_dimming :: proc(before,after:rl.Image,camera:rl.Camera3D,minimum,maximum:rl.Vector3) -> (f64,i32) {
	a:=rl.GetWorldToScreenEx(minimum,camera,before.width,before.height)
	b:=rl.GetWorldToScreenEx(maximum,camera,before.width,before.height)
	x0,x1:=clamp(i32(min(a.x,b.x)),0,before.width-1),clamp(i32(max(a.x,b.x)),0,before.width-1)
	y0,y1:=clamp(i32(min(a.y,b.y)),0,before.height-1),clamp(i32(max(a.y,b.y)),0,before.height-1)
	total:i64; count:i64; peak:i32
	for y in y0..=y1 {for x in x0..=x1 {
		p,q:=rl.GetImageColor(before,x,y),rl.GetImageColor(after,x,y)
		if p.a<250 || q.a<250 {continue}
		delta:=(i32(p.r)+i32(p.g)+i32(p.b)-i32(q.r)-i32(q.g)-i32(q.b))/3
		total+=i64(delta); count+=1; peak=max(peak,delta)
	}}
	return f64(total)/f64(max(count,1)),peak
}

maximum_difference :: proc(a,b:rl.Image) -> i32 {
	assert(a.width==b.width && a.height==b.height)
	difference:i32
	for y in 0..<a.height {for x in 0..<a.width {
		p,q:=rl.GetImageColor(a,x,y),rl.GetImageColor(b,x,y)
		difference=max(difference,abs(i32(p.r)-i32(q.r)),abs(i32(p.g)-i32(q.g)),abs(i32(p.b)-i32(q.b)),abs(i32(p.a)-i32(q.a)))
	}}
	return difference
}

expect :: proc(condition:bool,message:string) {
	if !condition {fmt.eprintln("FAIL:",message);failures+=1}
}
failures:int
capture:bool

View_State :: struct {
	view: bridge.Render_View3D,
	settings: bridge.Render_View3D_Settings,
	geometry: Geometry,
	ctx: ^bridge.Context,
}

foreground :: proc(data:rawptr,dimensions:[2]i32) -> bridge.Scene_Color_Overlay {
	s:=cast(^View_State)data
	return bridge.render_view_3d(&s.view,s.ctx,dimensions,s.settings,draw_geometry,&s.geometry)
}

capture_view :: proc(s:^View_State,size:[2]i32={320,240}) -> rl.Image {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	layer:=foreground(s,size)
	expect(layer.linear_color && layer.color.id!=0,"the regular foreground view returns linear HDR color")
	image:=rl.LoadImageFromTexture(layer.color)
	rl.ImageFlipVertical(&image)
	rl.EndDrawing()
	return image
}

scene_frame :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,s:^View_State,profile:^ecs.PostProcessing) -> rl.Image {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	assert(bridge.draw_scene_ex(ctx,w,manager,{scene_overlay=foreground,scene_overlay_data=s,post_processing_override=profile,background_color=rl.BLACK}))
	rl.DrawRectangle(0,0,16,16,rl.YELLOW)
	rlgl.DrawRenderBatchActive()
	image:=rl.LoadImageFromScreen()
	rl.EndDrawing()
	return image
}

coverage :: proc(image:rl.Image) -> int {
	count:int
	for y in 0..<image.height {for x in 0..<image.width {if rl.GetImageColor(image,x,y).a>250 {count+=1}}}
	return count
}

save :: proc(image:rl.Image,name:string) {
	if capture {assert(rl.ExportImage(image,fmt.ctprintf("build/foreground-view-validation/%s.png",name)))}
}

run :: proc() {
	if capture {assert(os.make_directory_all("build/foreground-view-validation")==nil)}
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,240,"Rune regular foreground render-view validation"); defer rl.CloseWindow()
	ctx,ready:=bridge.init(".",320,240); assert(ready); defer bridge.shutdown(&ctx)
	manager:=assets.init("."); defer assets.shutdown(&manager)
	s:=View_State{ctx=&ctx,settings=bridge.default_render_view_3d_settings(CAMERA)}
	s.geometry.mesh=r3d.GenMeshCube(1,1,1)
	defer r3d.UnloadMesh(s.geometry.mesh)
	defer bridge.destroy_render_view_3d(&s.view)
	s.geometry.contact=true; s.geometry.emission=0.75
	s.settings.post_processing.anti_aliasing=.disabled
	// The visible block front is 0.185 units ahead of the plate; the large
	// kernel must reach that front surface, not only its occluded side faces.
	s.settings.post_processing.ssao={enabled=false,radius=0.35,bias=0.001,intensity=3,power=1,sample_count=64,max_radius=0.35}
	// Deliberately different global/world values must survive the view capture.
	native:=r3d.GetEnvironment()^
	native.ssao.enabled=true; native.ssao.radius=3; native.ssao.intensity=0.23
	native.ambient.color={40,70,100,255}; native.ambient.energy=0.4
	r3d.SetEnvironment(&native)
	r3d.SetAntiAliasingMode(.FXAA)
	light:=r3d.CreateLight(.OMNI); defer r3d.DestroyLight(light)
	r3d.SetLightColor(light,rl.RED); r3d.SetLightPosition(light,{0,0,-0.4})
	r3d.SetLightEnergy(light,8); r3d.SetLightRange(light,3); r3d.EnableLight(light)
	before:=capture_view(&s); defer rl.UnloadImage(before)
	expect(r3d.GetEnvironment()^==native && r3d.GetAntiAliasingMode()==.FXAA && r3d.IsLightEnabled(light),"foreground capture restores world environment, antialiasing and enabled light state")
	width,height:i32; r3d.GetResolution(&width,&height)
	expect(width==320 && height==240,"foreground capture preserves the shared renderer resolution")
	corner:=rl.GetImageColor(before,8,8)
	expect(corner.a==0,"uncovered foreground pixels retain zero coverage")
	s.settings.post_processing.ssao.enabled=true
	on:=capture_view(&s); defer rl.UnloadImage(on)
	mean,peak:=patch_dimming(before,on,CAMERA,{0.13,-0.1,-0.975},{0.24,0.1,-0.975})
	remote,_:=patch_dimming(before,on,CAMERA,{-0.38,0.35,-0.975},{-0.35,0.38,-0.975})
	fmt.printf("Native foreground SSAO contact %.3f (peak %d), remote %.3f\n",mean,peak,remote)
	expect(mean>0.5 && peak>3,"the foreground runs native R3D SSAO around regular material contacts")
	expect(abs(remote)<4,"distant flat surfaces remain substantially unchanged")
	emitter_before:=pixel_at(before,CAMERA,{0.49,-0.2,-0.925})
	emitter_after:=pixel_at(on,CAMERA,{0.49,-0.2,-0.925})
	expect(abs(i32(emitter_before.b)-i32(emitter_after.b))<=3,"native emission is preserved while ambient light is occluded")
	save(before,"ao-off"); save(on,"ao-on")
	s.settings.post_processing.ssao.intensity=0
	zero:=capture_view(&s); defer rl.UnloadImage(zero)
	expect(maximum_difference(before,zero)<=3,"the view owns its SSAO intensity independently of the world profile")
	s.settings.post_processing.ssao.intensity=3; s.settings.post_processing.ssao.radius=0.002
	small:=capture_view(&s); defer rl.UnloadImage(small)
	small_mean,_:=patch_dimming(before,small,CAMERA,{0.13,-0.1,-0.975},{0.24,0.1,-0.975})
	expect(small_mean<mean,"the foreground SSAO radius is independently configurable")
	s.settings.post_processing.ssao.enabled=false; s.settings.post_processing.ssao.radius=0.35
	r3d.DisableLight(light)
	without_world_light:=capture_view(&s); defer rl.UnloadImage(without_world_light)
	expect(maximum_difference(before,without_world_light)<=3 && !r3d.IsLightEnabled(light),"isolated foreground lighting ignores world light changes and preserves disabled state")
	r3d.EnableLight(light)
	s.settings.inherit_lights=true
	with_world_light:=capture_view(&s); defer rl.UnloadImage(with_world_light)
	expect(maximum_difference(before,with_world_light)>8,"views may deliberately inherit regular R3D lights")
	for inherit in ([2]bool{false,true}) {for enabled in ([2]bool{false,true}) {
		if enabled {r3d.EnableLight(light)} else {r3d.DisableLight(light)}
		s.settings.inherit_lights=inherit
		s.settings.lights=[]r3d.Light{light,light}
		explicit:=capture_view(&s); defer rl.UnloadImage(explicit)
		expect(r3d.IsLightEnabled(light)==enabled,"explicit lights restore their original enabled state with duplicate handles and either inheritance mode")
		expect(maximum_difference(explicit,with_world_light)<=3,"an explicit light illuminates the view even when initially disabled or isolated")
	}}
	s.settings.lights=nil
	s.settings.inherit_lights=false
	s.settings.post_processing.fog.mode=.linear; s.settings.post_processing.fog.color={0,0,0,255}; s.settings.post_processing.fog.start=0; s.settings.post_processing.fog.end=0.5
	fogged:=capture_view(&s); defer rl.UnloadImage(fogged)
	expect(maximum_difference(before,fogged)>20,"a foreground view can select its own regular post-processing effects")
	s.settings.post_processing.fog.mode=.disabled
	s.settings.camera.fovy=42
	zoomed:=capture_view(&s,{192,128}); defer rl.UnloadImage(zoomed)
	expect(zoomed.width==192 && zoomed.height==128 && coverage(zoomed)>0,"a resized view keeps its independent camera and valid coverage")
	r3d.GetResolution(&width,&height)
	expect(width==320 && height==240 && r3d.GetEnvironment()^==native,"resizing a foreground target leaves the world resolution and profile intact")
	s.settings.camera=CAMERA
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,camera,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&w,&registry,camera,ecs.Camera3D{active=true,target={0,0,-1},up={0,1,0},fovy=60}))
	ambient:=ecs.create_entity(&w); assert(ecs.add(&w,&registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=1}))
	wall:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,wall,ecs.Transform{position={0,0,-0.25},scale={5,5,0.1}}))
	wall_mesh:=ecs.MeshRenderer{primitive="cube",color={180,20,20,255}}
	assert(ecs.add(&w,&registry,wall,wall_mesh))
	world_profile:=ecs.default_post_processing(); world_profile.anti_aliasing=.disabled
	world_profile.ssao.enabled=false; world_profile.ssgi.enabled=false; world_profile.ssil.enabled=false
	world_profile.bloom.mode=.disabled; world_profile.fog.mode=.disabled
	composed:=scene_frame(&ctx,&w,&manager,&s,&world_profile); defer rl.UnloadImage(composed)
	p:=pixel_at(composed,CAMERA,{0,0.25,-0.975})
	expect(abs(i32(p.r)-i32(p.g))<12 && p.r>80,"nearer world geometry cannot occlude the foreground view")
	c:=rl.GetImageColor(composed,24,24)
	expect(c.r>c.g+30,"transparent foreground pixels preserve the world")
	hud:=rl.GetImageColor(composed,8,8)
	expect(hud.r>200 && hud.g>200 && hud.b<40,"HUD draws above the shared final composite")
	save(composed,"composed")
	r3d.DisableLight(light)
	wall_mesh.color={0,0,0,255}; assert(ecs.set(&w,wall,wall_mesh))
	s.geometry.emission=5
	hdr:=capture_view(&s); defer rl.UnloadImage(hdr)
	emission_radiance:=radiance_at(hdr,CAMERA,{0.49,-0.2,-0.925})
	fmt.printf("Foreground native HDR emitter radiance %.3f\n",emission_radiance)
	expect(emission_radiance>1.1,"the regular foreground pipeline preserves radiance above display white")
	no_bloom:=scene_frame(&ctx,&w,&manager,&s,&world_profile); defer rl.UnloadImage(no_bloom)
	world_profile.bloom.mode=.additive; world_profile.bloom.intensity=0.5; world_profile.bloom.threshold=1; world_profile.bloom.filter_radius=1
	bloom:=scene_frame(&ctx,&w,&manager,&s,&world_profile); defer rl.UnloadImage(bloom)
	fringe:i32
	for y in 0..<bloom.height {for x in 0..<bloom.width {
		a:=rl.GetImageColor(no_bloom,x,y)
		if a.r>2 || a.g>2 || a.b>2 {continue}
		b:=rl.GetImageColor(bloom,x,y)
		fringe=max(fringe,i32(b.b)-i32(a.b))
	}}
	fmt.printf("Foreground HDR emission bloom fringe %d\n",fringe)
	expect(fringe>3,"native foreground emission remains HDR and feeds the shared final bloom")
	save(bloom,"bloom")
	s.geometry.missing=true
	empty:=capture_view(&s); defer rl.UnloadImage(empty)
	expect(coverage(empty)==0,"later empty views cannot retain previous geometry coverage")
	bridge.destroy_render_view_3d(&s.view); bridge.destroy_render_view_3d(&s.view)
	expect(s.view.target.id==0,"repeated foreground-view cleanup releases its target")
	if failures>0 {os.exit(1)}
	fmt.println("Regular foreground render-view GPU validation passed: native SSAO, independent profile, lighting/state isolation, depth, HDR emission, composition, resize and cleanup.")
}

main :: proc() {
	runtime:bool
	for arg in os.args[1:] {if arg=="--runtime" {runtime=true};if arg=="--capture" {capture=true}}
	if !runtime {fmt.println("Foreground render-view GPU checks skipped (use --runtime)");return}
	run()
}
