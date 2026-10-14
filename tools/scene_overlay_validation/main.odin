package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import "rune:particles"
import bridge "rune:r3d_bridge"
import "rune:render"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

Overlay_State :: struct {
	color, emission: render.Overlay3D,
	calls: int,
	emission_energy: f32,
	missing, alpha_check: bool,
}

CAMERA :: rl.Camera3D{position={},target={0,0,-1},up={0,1,0},fovy=60,projection=.PERSPECTIVE}

draw_overlay :: proc(data: rawptr, framebuffer: [2]i32) -> bridge.Scene_Color_Overlay {
	s:=cast(^Overlay_State)data
	s.calls+=1
	if s.missing {return {}}
	assert(render.begin_overlay_3d(&s.color,CAMERA,framebuffer[0],framebuffer[1]))
	if s.alpha_check {
		rl.DrawCube({0,0,-1},0.4,0.4,0.1,{255,0,0,128})
		live:=[1]particles.Particle3D{{position={0.4,0,-1},lifetime=1,start_size=0.1,end_size=0.1,start_color={0,255,255,128},end_color={0,255,255,128}}}
		render.draw_particles_3d(live[:])
	} else {
		rl.DrawCube({0,0,-1},0.5,0.5,0.1,{210,60,25,255})
		rl.DrawCube({0,0,-2},0.8,0.8,0.1,rl.GREEN) // behind foreground body
		rl.DrawCube({-0.4,0.3,-1},0.1,0.1,0.1,rl.GREEN) // asymmetric orientation marker
	}
	assert(render.finish_overlay_3d(&s.color))
	assert(!render.finish_overlay_3d(&s.color),"an already finished pass cannot end the scene framebuffer")
	assert(render.begin_overlay_3d(&s.emission,CAMERA,framebuffer[0],framebuffer[1]))
	rl.DrawCube({0,0,-1},0.5,0.5,0.1,rl.BLACK)
	rl.DrawCube({0,0,-2},0.1,0.1,0.1,rl.WHITE) // emitter hidden behind body
	rl.DrawCube({0.28,0,-0.9},0.02,0.08,0.03,{80,255,255,255})
	assert(render.finish_overlay_3d(&s.emission))
	return {color=s.color.target.texture,emission=s.emission.target.texture,emission_energy=s.emission_energy}
}

draw_frame :: proc(ctx: ^bridge.Context,w: ^ecs.World,manager: ^assets.Asset_Manager,s: ^Overlay_State,profile: ^ecs.PostProcessing,sampling_fovy: f32 = 0) -> rl.Image {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	assert(bridge.draw_scene_ex(ctx,w,manager,{scene_overlay=draw_overlay,scene_overlay_data=s,post_processing_override=profile,sampling_fovy=sampling_fovy,background_color=rl.BLACK}))
	rl.DrawRectangle(0,0,16,16,rl.YELLOW)
	rlgl.DrawRenderBatchActive()
	image:=rl.LoadImageFromScreen()
	rl.EndDrawing()
	return image
}

sample :: proc(image: rl.Image,point: rl.Vector3) -> rl.Color {
	pixel:=rl.GetWorldToScreenEx(point,CAMERA,image.width,image.height)
	return rl.GetImageColor(image,i32(pixel.x),i32(pixel.y))
}

main :: proc() {
	runtime := false
	for arg in os.args[1:] {if arg == "--runtime" {runtime = true}}
	if !runtime {
		fmt.println("Scene HDR overlay GPU validation skipped (use --runtime)")
		return
	}
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,240,"Rune HDR scene overlay validation")
	defer rl.CloseWindow()
	ctx,ok:=bridge.init(".",320,240); assert(ok); defer bridge.shutdown(&ctx)
	manager:=assets.init("."); defer assets.shutdown(&manager)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,camera,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&w,&registry,camera,ecs.Camera3D{active=true,target={0,0,-1},up={0,1,0},fovy=60}))
	wall:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,wall,ecs.Transform{position={0,0,-0.3},scale={5,5,0.1}}))
	assert(ecs.add(&w,&registry,wall,ecs.MeshRenderer{primitive="cube",color={0,0,0,255}}))
	s: Overlay_State
	defer render.destroy_overlay_3d(&s.color)
	defer render.destroy_overlay_3d(&s.emission)
	p:=ecs.default_post_processing(); p.anti_aliasing=.disabled
	base:=draw_frame(&ctx,&w,&manager,&s,&p); defer rl.UnloadImage(base)
	center:=sample(base,{0,0,-1})
	fmt.println("base",center)
	assert(center.r>180 && center.g<100 && center.b<70,"nearer world wall and farther foreground geometry must not obscure overlay")
	marker:=sample(base,{-0.4,0.3,-1})
	assert(marker.g>100 && marker.g>marker.r,"render texture and screen orientation must match")
	p.color.saturation=0
	mono:=draw_frame(&ctx,&w,&manager,&s,&p); defer rl.UnloadImage(mono)
	gray:=sample(mono,{0,0,-1}); fmt.println("saturation zero",gray)
	assert(abs(i32(gray.r)-i32(gray.g))<=3 && abs(i32(gray.r)-i32(gray.b))<=3,"output color effects must process foreground color")
	hud:=rl.GetImageColor(mono,8,8)
	assert(hud.r>200 && hud.g>200 && hud.b<40,"HUD remains above post processing")
	p.color.saturation=1; p.tonemap.exposure=0.25
	dim:=draw_frame(&ctx,&w,&manager,&s,&p); defer rl.UnloadImage(dim)
	dim_center:=sample(dim,{0,0,-1}); fmt.println("exposure quarter",dim_center)
	assert(i32(dim_center.r)<i32(center.r)-20,"scene exposure must process foreground color")
	p.tonemap.exposure=1
	crop:=draw_frame(&ctx,&w,&manager,&s,&p,80); defer rl.UnloadImage(crop)
	crop_center:=sample(crop,{0,0,-1})
	crop_marker:=sample(crop,{-0.4,0.3,-1})
	assert(abs(i32(crop_center.r)-i32(center.r))<3 && crop_marker.g>100,"sampling crop keeps the foreground lens and texture orientation stable")
	s.emission_energy=8
	no_bloom:=draw_frame(&ctx,&w,&manager,&s,&p); defer rl.UnloadImage(no_bloom)
	emitter_core:=sample(no_bloom,{0.28,0,-0.9})
	assert(emitter_core.b>200,"emission radiance must reach scene color before bloom")
	p.bloom.mode=.additive; p.bloom.intensity=0.6; p.bloom.threshold=1; p.bloom.filter_radius=1
	bloom:=draw_frame(&ctx,&w,&manager,&s,&p); defer rl.UnloadImage(bloom)
	// The thin emitter's halo depends on mip sampling. Find its brightest newly
	// illuminated pixel outside geometry, rather than assume a fixed halo radius.
	fringe_max:=i32(0)
	for y in 0..<bloom.height {
		for x in 0..<bloom.width {
			before:=rl.GetImageColor(no_bloom,x,y)
			if before.r!=0 || before.g!=0 || before.b!=0 {continue}
			after:=rl.GetImageColor(bloom,x,y)
			fringe_max=max(fringe_max,i32(after.b))
		}
	}
	fmt.println("bloom outside geometry",fringe_max)
	assert(fringe_max>3,"HDR foreground emission must feed the world bloom pass")
	s.missing=true; p.bloom.mode=.disabled
	missing:=draw_frame(&ctx,&w,&manager,&s,&p); defer rl.UnloadImage(missing)
	assert(sample(missing,{0,0,-1}).r<10,"missing overlays must not retain a previous frame's texture chain")
	s.missing=false; s.emission_energy=0; s.alpha_check=true
	alpha_frame:=draw_frame(&ctx,&w,&manager,&s,&p); defer rl.UnloadImage(alpha_frame)
	alpha_image:=rl.LoadImageFromTexture(s.color.target.texture); defer rl.UnloadImage(alpha_image)
	coverage:=rl.GetImageColor(alpha_image,alpha_image.width/2,alpha_image.height/2)
	fmt.println("captured premultiplied coverage",coverage)
	assert(abs(i32(coverage.r)-128)<=2 && abs(i32(coverage.a)-128)<=2,"transparent capture stores premultiplied color with unsquared alpha")
	particle_pixel:=rl.GetWorldToScreenEx({0.4,0,-1},CAMERA,alpha_image.width,alpha_image.height)
	light:=rl.GetImageColor(alpha_image,i32(particle_pixel.x),alpha_image.height-1-i32(particle_pixel.y))
	assert(light.g>80 && light.b>80 && light.a==0,"additive particles contribute light without hiding the scene")
	assert(s.calls==8,"callback runs once per scene draw")
	assert(ctx.scene_overlay_shader!=nil && len(manager.diagnostics.reported)==0,"scene overlay shader compiles without asset diagnostics")
	fmt.println("Scene HDR overlay GPU validation passed: isolated depth, orientation, output color, exposure, bloom, crop, HUD, missing frame, premultiplied alpha and additive particles.")
}
