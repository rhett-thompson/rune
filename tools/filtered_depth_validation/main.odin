package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

OUTPUT :: "build/filtered-depth-validation"
CAMERA :: rl.Camera3D{position={},target={0,0,-1},up={0,1,0},fovy=60,projection=.PERSPECTIVE}

DEFORMED_SHADER :: `#pragma usage opaque
uniform float u_time;
varying float v_local_x;
void vertex() {
    v_local_x = POSITION.x;
    POSITION.z += u_time;
}
void fragment() {
    if (v_local_x > 0.0) discard;
}`

// The owned depth texture stores view-space metres. Convert readback to a
// known float layout without normalizing it through an eight-bit color API.
read_depth :: proc(texture:rl.Texture2D,point:rl.Vector3) -> f32 {
	image:=rl.LoadImageFromTexture(texture)
	assert(image.data!=nil,"depth readback must have pixels")
	defer rl.UnloadImage(image)
	rl.ImageFormat(&image,.UNCOMPRESSED_R32G32B32A32)
	rl.ImageFlipVertical(&image)
	p:=rl.GetWorldToScreenEx(point,CAMERA,image.width,image.height)
	x,y:=clamp(i32(p.x),0,image.width-1),clamp(i32(p.y),0,image.height-1)
	values:=cast([^]f32)image.data
	return values[(y*image.width+x)*4]
}

save_depth :: proc(texture:rl.Texture2D,name:string) {
	image:=rl.LoadImageFromTexture(texture)
	assert(image.data!=nil)
	defer rl.UnloadImage(image)
	rl.ImageFormat(&image,.UNCOMPRESSED_R32G32B32A32)
	rl.ImageFlipVertical(&image)
	values:=cast([^]f32)image.data
	for i in 0..<int(image.width*image.height) {
		depth:=values[i*4]
		level:=clamp(depth/10,0,1) if depth<20 else f32(0)
		values[i*4],values[i*4+1],values[i*4+2],values[i*4+3]=level,level,level,1
	}
	rl.ImageFormat(&image,.UNCOMPRESSED_R8G8B8A8)
	assert(rl.ExportImage(image,fmt.ctprintf(OUTPUT+"/%s.png",name)))
}

scene_frame :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,profile:^ecs.PostProcessing,filter:bridge.Depth_Pass_Filter,filtered:bool,name:string) -> (rl.Color,f32) {
	settings:=bridge.Scene3D_Settings{background_color=rl.BLACK,post_processing_override=profile,material_time=0,material_time_override=true}
	for _ in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		if filtered {assert(bridge.draw_scene_with_filtered_depth(ctx,w,manager,settings,filter))}
		else {assert(bridge.draw_scene_ex(ctx,w,manager,settings))}
		rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen();assert(image.data!=nil);defer rl.UnloadImage(image)
	assert(rl.ExportImage(image,fmt.ctprintf(OUTPUT+"/%s.png",name)))
	color:=rl.GetImageColor(image,image.width/2,image.height/2)
	// Native GetBufferDepth is positive linear view-space depth. Comparing reads
	// verifies that the auxiliary pass never replaces the ordinary scene depth.
	depth:=read_depth(r3d.GetBufferDepth(),{0,0,-4})
	return color,depth
}

read_screen_color :: proc(point:rl.Vector3) -> rl.Color {
	image:=rl.LoadImageFromScreen();assert(image.data!=nil);defer rl.UnloadImage(image)
	p:=rl.GetWorldToScreenEx(point,CAMERA,image.width,image.height)
	return rl.GetImageColor(image,clamp(i32(p.x),0,image.width-1),clamp(i32(p.y),0,image.height-1))
}

auxiliary_frame :: proc(view:^bridge.Depth_Pass3D,ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,filter:bridge.Depth_Pass_Filter,time:f32=0) {
	rl.BeginDrawing()
	assert(bridge.render_scene_depth(view,ctx,w,manager,CAMERA,filter,time))
	rl.EndDrawing()
	assert(view.valid && view.target.id!=0 && view.target.texture.id!=0)
}

box :: proc(w:^ecs.World,r:^ecs.Component_Registry,position,size:[3]f32,material:string) -> ecs.Entity {
	e:=ecs.create_entity(w)
	assert(ecs.add(w,r,e,ecs.Transform{position=position,scale=size}))
	assert(ecs.add(w,r,e,ecs.MeshRenderer{primitive="cube",material=material,color={255,255,255,255},shadows=false}))
	return e
}

main :: proc() {
	assert(os.make_directory_all(OUTPUT)==nil || os.is_dir(OUTPUT))
	// Emissive lit materials write opaque depth before pre-transparency effects,
	// matching ordinary architecture. Native unlit draws happen later.
	assert(os.write_entire_file(OUTPUT+"/beam.material.json",`{"lighting":true,"base_color":[0,0,0,255],"emission_color":[240,30,20,255],"emission_energy":1}`)==nil)
	assert(os.write_entire_file(OUTPUT+"/wall.material.json",`{"lighting":true,"base_color":[0,0,0,255],"emission_color":[20,50,240,255],"emission_energy":1}`)==nil)
	assert(os.write_entire_file(OUTPUT+"/unlit-wall.material.json",`{"lighting":false,"base_color":[20,50,240,255]}`)==nil)
	assert(os.write_entire_file(OUTPUT+"/deformed.material.json",`{"lighting":true,"base_color":[0,0,0,255],"emission_color":[20,50,240,255],"emission_energy":1,"surface_shader":"deformed.glsl","surface_shader_time":true}`)==nil)
	assert(os.write_entire_file(OUTPUT+"/deformed.glsl",DEFORMED_SHADER)==nil)
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,240,"Rune filtered-depth validation");defer rl.CloseWindow()
	rlgl.SetClipPlanes(0.1,100)
	manager:=assets.init(OUTPUT);defer assets.shutdown(&manager)
	ctx,ready:=bridge.init(OUTPUT,320,240);assert(ready);defer bridge.shutdown(&ctx)
	ctx.match_framebuffer=false
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,camera,ecs.default_transform()))
	assert(ecs.add(&w,&r,camera,ecs.Camera3D{active=true,target=CAMERA.target,up=CAMERA.up,fovy=CAMERA.fovy}))
	beam:=box(&w,&r,{0,0,-4},{1.8,1.8,0.2},"beam.material.json")
	// Low Heaven's beams are render-only CPU meshes. Exercise that submission
	// path alongside the ordinary primitive wall rather than test only cubes.
	beam_renderer,_:=ecs.get_mesh_renderer(&w,beam);beam_renderer.primitive="static"
	assert(ecs.set_mesh_renderer(&w,beam,beam_renderer))
	voxels:=[1]u8{1};palette:=[2][4]u8{{},{255,255,255,255}}
	beam_mesh,mesh_ok:=geometry.surface({size={1,1,1},cells=voxels[:],origin={-0.5,-0.5,-0.5},spacing=1},palette[:])
	assert(mesh_ok);defer geometry.destroy_mesh(&beam_mesh)
	assert(ecs.set_static_mesh_owned(&w,beam,&beam_mesh,collidable=false))
	wall:=box(&w,&r,{0,0,-8},{3.5,2,0.2},"wall.material.json")
	source:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,source,ecs.Transform{position={0,0,-50},scale={1,1,1}}))
	ecs.set_entity_metadata(&w,source,"shaft_source","","",ecs.Default_Layer_Mask)
	ignored:=[1]ecs.Entity{beam}
	filter:=bridge.Depth_Pass_Filter{ignored_subtrees=ignored[:]}
	profile:=ecs.default_post_processing();profile.enabled=true;profile.anti_aliasing=.disabled
	profile.light_shafts.enabled=true;profile.light_shafts.source="shaft_source";profile.light_shafts.intensity=0.001
	before,before_depth:=scene_frame(&ctx,&w,&manager,&profile,{},false,"ordinary-scene")
	assert(before.r>before.b*2,"the normal scene must show the foreground red beam")
	assert(ctx.filtered_depth.target.id==0,"ordinary rendering must not allocate the auxiliary depth target")
	view:bridge.Depth_Pass3D;defer bridge.destroy_depth_pass_3d(&view)
	rl.BeginDrawing()
	assert(!bridge.render_scene_depth(&view,&ctx,&w,&manager,CAMERA,{},0))
	rl.EndDrawing()
	assert(view.target.id==0 && !view.valid,"an empty filter must not allocate or render an auxiliary pass")
	auxiliary_frame(&view,&ctx,&w,&manager,filter)
	wall_depth:=read_depth(view.target.texture,{0,0,-8})
	sky_depth:=read_depth(view.target.texture,{0,0.75,-4})
	fmt.printf("Filtered wall depth %.4f, sky depth %.4f; expected wall 7.9 and far 100.\n",wall_depth,sky_depth)
	assert(abs(wall_depth-7.9)<0.08,"excluding the foreground beam must reveal rear-wall depth rather than clear it to far")
	assert(sky_depth>99,"excluding a beam over open sky must preserve far-plane depth")
	save_depth(view.target.texture,"filtered-depth")
	after,after_depth:=scene_frame(&ctx,&w,&manager,&profile,filter,true,"scene-with-filtered-depth")
	assert(after.r>after.b*2,"excluding the beam from auxiliary depth must not hide it from ordinary rendering")
	assert(abs(after_depth-before_depth)<0.0005,"the normal scene depth must retain the foreground beam")
	assert(ctx.filtered_depth.valid && ctx.filtered_depth.target.id!=0,"the shaft consumer must use the opt-in filtered depth")
	// This point is on the red beam but above the included rear wall's projected
	// silhouette. The shaft shader must see open sky there only in the filtered
	// view; checking a texture alone would not prove sampler consumption.
	profile.light_shafts.intensity=1
	probe:=rl.Vector3{0,0.75,-4}
	_,_=scene_frame(&ctx,&w,&manager,&profile,{},false,"shafts-ordinary-depth")
	ordinary_shafts:=read_screen_color(probe)
	_,_=scene_frame(&ctx,&w,&manager,&profile,filter,true,"shafts-filtered-depth")
	filtered_shafts:=read_screen_color(probe)
	passes:=ctx.filtered_depth.pass_count
	_,_=scene_frame(&ctx,&w,&manager,&profile,{},false,"shafts-ordinary-depth-restored")
	restored_shafts:=read_screen_color(probe)
	fmt.printf("Shaft probe ordinary=%v filtered=%v restored=%v\n",ordinary_shafts,filtered_shafts,restored_shafts)
	assert(i32(filtered_shafts.b)>i32(ordinary_shafts.b)+10,"the shaft shader must consume the filtered depth and add light over the excluded beam")
	assert(abs(i32(restored_shafts.r)-i32(ordinary_shafts.r))<=2 && abs(i32(restored_shafts.g)-i32(ordinary_shafts.g))<=2 && abs(i32(restored_shafts.b)-i32(ordinary_shafts.b))<=2,"ordinary rendering must restore the original shaft depth rather than reuse the filtered sampler")
	assert(!ctx.filtered_depth.valid && ctx.filtered_depth.pass_count==passes,"returning to the ordinary path must perform no auxiliary pass")
	profile.light_shafts.intensity=0.001
	// Existing unlit materials draw after the native opaque linear-depth pass.
	// Filtered depth must retain that membership rather than promote them to
	// shaft occluders simply because final raw hardware depth contains them.
	renderer,_:=ecs.get_mesh_renderer(&w,wall);renderer.material="unlit-wall.material.json";assert(ecs.set_mesh_renderer(&w,wall,renderer))
	auxiliary_frame(&view,&ctx,&w,&manager,filter)
	testing_unlit_depth:=read_depth(view.target.texture,{0,0,-8})
	assert(testing_unlit_depth>99,"filtering must preserve existing unlit-material occlusion behavior")
	// Reusing the original shader inputs must retain both cutouts and displaced
	// vertex positions in the auxiliary pass, with the same explicit material clock.
	renderer.material="deformed.material.json";assert(ecs.set_mesh_renderer(&w,wall,renderer))
	auxiliary_frame(&view,&ctx,&w,&manager,filter,0)
	cut_wall:=read_depth(view.target.texture,{-0.6,0,-8})
	cut_sky:=read_depth(view.target.texture,{0.6,0,-8})
	assert(abs(cut_wall-7.9)<0.08 && cut_sky>99,"material cutouts must remain holes in the filtered depth pass")
	auxiliary_frame(&view,&ctx,&w,&manager,filter,1)
	displaced:=read_depth(view.target.texture,{-0.6,0,-8})
	assert(abs(displaced-7.7)<0.08,"material vertex deformation and explicit shader time must affect the filtered depth")
	save_depth(view.target.texture,"cutout-displaced-depth")
	r3d.SetResolution(192,128)
	auxiliary_frame(&view,&ctx,&w,&manager,filter,0)
	assert(view.target.texture.width==192 && view.target.texture.height==128,"the auxiliary target must follow native internal resolution")
	assert(abs(read_depth(view.target.texture,{-0.6,0,-8})-7.9)<0.08,"resizing must retain projection-aligned depth")
	bridge.destroy_depth_pass_3d(&view)
	assert(view.target.id==0 && !view.valid,"destroying the depth pass must clear its target and validity")
	fmt.println("Filtered-depth GPU geometry, rear-wall preservation, normal-depth isolation, cutouts, vertex deformation, resize and cleanup passed")
}
