package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import "rune:assets"
import "rune:ecs"
import "rune:jobs"
import "rune:terrain"
import bridge "rune:r3d_bridge"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import r3d "r3d:r3d"
import stbi "vendor:stb/image"

Gate :: struct {group: jobs.Group, started, release: sync.Sema, released: bool}
block_worker :: proc(data: rawptr) {
	gate:=(^Gate)(data); sync.sema_post(&gate.started); sync.sema_wait(&gate.release)
}
increment :: proc(data: rawptr) {(^int)(data)^+=1}
hold :: proc(pool: ^jobs.Pool, gate: ^Gate) {
	assert(jobs.submit(pool,&gate.group,block_worker,gate))
	assert(sync.sema_wait_with_timeout(&gate.started,2*time.Second))
}
release :: proc(gate: ^Gate) {
	if !gate.released {sync.sema_post(&gate.release);gate.released=true}
	jobs.wait(&gate.group)
}

defaults :: proc() -> assets.Material_Data {
	return {base_color={255,255,255,255},filter="point",lighting=true,normal_scale=1,ao_strength=1,roughness=0.8,specular=0.5}
}
solid_procedural :: proc(color: rl.Color) -> assets.Material_Data {
	data:=defaults();data.procedural=assets.default_procedural_material();data.procedural.resolution=32
	data.procedural.color_a={color.r,color.g,color.b,color.a};data.procedural.color_b=data.procedural.color_a
	return data
}
pixel :: proc(texture: rl.Texture2D) -> rl.Color {
	assert(texture.id!=0)
	image:=rl.LoadImageFromTexture(texture);assert(rl.IsImageValid(image));defer rl.UnloadImage(image)
	return rl.GetImageColor(image,0,0)
}
expect_color :: proc(texture: rl.Texture2D, expected: rl.Color, tolerance: i32 = 0) {
	actual:=pixel(texture)
	assert(abs(i32(actual.r)-i32(expected.r))<=tolerance && abs(i32(actual.g)-i32(expected.g))<=tolerance &&
		abs(i32(actual.b)-i32(expected.b))<=tolerance && abs(i32(actual.a)-i32(expected.a))<=tolerance,
		fmt.tprintf("texture color mismatch: expected %v, actual %v",expected,actual))
}
expect_srgb :: proc(texture: rl.Texture2D, alpha: bool) {
	gl.BindTexture(gl.TEXTURE_2D,texture.id)
	internal: i32; gl.GetTexLevelParameteriv(gl.TEXTURE_2D,0,gl.TEXTURE_INTERNAL_FORMAT,&internal)
	gl.BindTexture(gl.TEXTURE_2D,0)
	expected:=i32(gl.SRGB8_ALPHA8) if alpha else i32(gl.SRGB8)
	assert(internal==expected,fmt.tprintf("expected sRGB internal format %x, got %x",expected,internal))
}
write_image :: proc(path: string, color: rl.Color, jpeg: bool = false) {
	image:=rl.GenImageColor(16,16,color);defer rl.UnloadImage(image)
	if jpeg {
		rl.ImageFormat(&image,.UNCOMPRESSED_R8G8B8)
		assert(stbi.write_jpg(fmt.ctprintf("%s",path),16,16,3,image.data,95)!=0)
	} else {assert(rl.ExportImage(image,fmt.ctprintf("%s",path)))}
}
wait_requests :: proc(ctx: ^bridge.Context) {
	for _,request in ctx.material_reloads {jobs.wait(&request.group)}
}
get :: proc(ctx: ^bridge.Context, manager: ^assets.Asset_Manager, key: string, data: assets.Material_Data) -> r3d.Material {
	return bridge.material_from_data(ctx,manager,key,data)
}
invalidate_source :: proc(manager: ^assets.Asset_Manager, path: string) {
	manager.material_texture_watches[path]=-2
	assets.refresh_materials(manager)
}

headless :: proc() {
	data:=solid_procedural(rl.RED)
	assert(bridge.material_reload_supported(data))
	data=defaults();data.texture="test.PNG";assert(bridge.material_reload_supported(data))
	data.texture="test.jpeg";assert(bridge.material_reload_supported(data))
	data.roughness_texture="channel.png";assert(!bridge.material_reload_supported(data))
	data=defaults();data.texture="native.dds";assert(!bridge.material_reload_supported(data))
	ctx:bridge.Context
	ready,deferred:=bridge.prepare_material_reload(&ctx,nil,"key",data,0,0,{})
	assert(ready==nil && !deferred,"unconfigured contexts keep synchronous material loading")
	bridge.pump_material_jobs(nil);bridge.pump_material_jobs(&ctx)
	assert(ctx.material_reload_tick==1 && len(ctx.material_reloads)==0)
	fmt.println("Material async policy checks passed; use --runtime for native decoding/upload and lifecycle checks")
}

main :: proc() {
	runtime:=false
	for arg in os.args[1:] {if arg=="--runtime" {runtime=true} else {fmt.eprintln("Usage: material_async_validation [--runtime]");os.exit(2)}}
	headless()
	if runtime {validate_runtime()}
}

validate_runtime :: proc() {
	rl.SetTraceLogLevel(.WARNING);rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(128,128,"Asynchronous material reload validation");defer rl.CloseWindow()
	assert(rl.IsWindowReady())
	gl.load_up_to(3,3,proc(pointer: rawptr,name: cstring) {(^rawptr)(pointer)^=rlgl.GetProcAddress(name)})
	root,error:=os.make_directory_temp("build","material-async-validation-*",context.allocator);assert(error==nil);defer delete(root)
	png:=fmt.aprintf("%s/source.png",root);defer delete(png)
	jpeg:=fmt.aprintf("%s/source_jpeg.png",root);defer delete(jpeg)
	material_path:=fmt.aprintf("%s/proc.material.json",root);defer delete(material_path)
	// This raylib artifact lacks JPEG file loading. Begin with PNG pixels, then
	// replace the same supported path with JPEG bytes for the private decoder.
	write_image(png,{210,70,40,255});write_image(jpeg,{50,130,210,255})
	assert(os.write_entire_file(material_path,`{"filter":"point","mipmaps":false,"lighting":true,"base_color":[255,255,255,255],"procedural":{"resolution":32,"color_a":[230,41,55,255],"color_b":[230,41,55,255]}}`)==nil)
	pool:=jobs.create(1,1);assert(pool!=nil);defer jobs.destroy(pool)
	manager:=assets.init(root);defer assets.shutdown(&manager)
	second_manager:=assets.init(root);defer assets.shutdown(&second_manager)
	ctx,ok:=bridge.init(root,128,128,worker_pool=pool);assert(ok);defer bridge.shutdown(&ctx)
	bridge.pump_material_jobs(&ctx)
	gate:Gate;hold(pool,&gate);defer release(&gate)
	initial:=bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	assert(initial.albedo.texture.id!=0 && len(ctx.material_reloads)==0,"first procedural load is synchronous with all workers blocked")
	expect_color(initial.albedo.texture,rl.RED);expect_srgb(initial.albedo.texture,true)
	other_data:=solid_procedural(rl.RED)
	other:=get(&ctx,&manager,"other",other_data)
	image_data:=defaults();image_data.texture="source.png"
	image_material:=get(&ctx,&manager,"image",image_data);expect_color(image_material.albedo.texture,{210,70,40,255});expect_srgb(image_material.albedo.texture,true)
	jpeg_data:=defaults();jpeg_data.texture="source_jpeg.png"
	jpeg_material:=get(&ctx,&manager,"jpeg",jpeg_data);expect_color(jpeg_material.albedo.texture,{50,130,210,255});expect_srgb(jpeg_material.albedo.texture,true)
	assert(len(ctx.material_reloads)==0,"first direct image loads also remain synchronous")
	base,base_ok:=assets.material_data(&manager,"proc.material.json");assert(base_ok)
	blue:=base;blue.procedural.color_a={0,121,241,255};blue.procedural.color_b=blue.procedural.color_a
	assert(assets.set_material_preview(&manager,"proc.material.json",blue))
	pending:=bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	assert(pending.albedo.texture.id==initial.albedo.texture.id && len(ctx.material_reloads)==1)
	other_data=solid_procedural(rl.GREEN)
	deferred:=get(&ctx,&manager,"other",other_data)
	assert(deferred.albedo.texture.id==other.albedo.texture.id && len(ctx.material_reloads)==1 && ctx.frame_stats.material_reload_deferred>0,
		"a full job queue keeps the old material without inline CPU generation")
	release(&gate);wait_requests(&ctx)
	pending=bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	assert(pending.albedo.texture.id==initial.albedo.texture.id,"completion during a draw cannot install before the next pump")
	bridge.pump_material_jobs(&ctx)
	current:=bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	assert(current.albedo.texture.id!=initial.albedo.texture.id);expect_color(current.albedo.texture,rl.BLUE);expect_srgb(current.albedo.texture,true)
	get(&ctx,&manager,"other",other_data);wait_requests(&ctx);bridge.pump_material_jobs(&ctx)
	other=get(&ctx,&manager,"other",other_data);expect_color(other.albedo.texture,rl.GREEN)

	// A preview superseded while queued cannot install its obsolete pixels.
	stale_gate:Gate;hold(pool,&stale_gate);defer release(&stale_gate)
	preview_a:=blue;preview_a.procedural.color_a={255,161,0,255};preview_a.procedural.color_b=preview_a.procedural.color_a
	preview_b:=blue;preview_b.procedural.color_a={200,122,255,255};preview_b.procedural.color_b=preview_b.procedural.color_a
	assert(assets.set_material_preview(&manager,"proc.material.json",preview_a))
	bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	assert(assets.set_material_preview(&manager,"proc.material.json",preview_b))
	bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	release(&stale_gate);wait_requests(&ctx);bridge.pump_material_jobs(&ctx)
	stale_id:=current.albedo.texture.id
	current=bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	assert(current.albedo.texture.id==stale_id && ctx.frame_stats.material_reload_discarded>0)
	bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	wait_requests(&ctx);bridge.pump_material_jobs(&ctx)
	current=bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255});expect_color(current.albedo.texture,rl.PURPLE)

	validate_direct_repair(&ctx,&manager,"image",image_data,png,"source.png",{80,210,50,255},false)
	validate_direct_repair(&ctx,&manager,"jpeg",jpeg_data,jpeg,"source_jpeg.png",{200,90,40,255},true)
	validate_direct_repair(&ctx,&manager,"jpeg",jpeg_data,jpeg,"source_jpeg.png",{60,160,80,255},true)

	// Two completed replacements still install at most one per boundary.
	final_preview:=preview_b;final_preview.procedural.color_a={255,255,255,255};final_preview.procedural.color_b=final_preview.procedural.color_a
	assert(assets.set_material_preview(&manager,"proc.material.json",final_preview))
	bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255});wait_requests(&ctx)
	other_data=solid_procedural(rl.YELLOW)
	get(&ctx,&manager,"other",other_data);wait_requests(&ctx)
	assert(len(ctx.material_reloads)==2)
	completed:=ctx.frame_stats.material_reload_completed
	bridge.pump_material_jobs(&ctx)
	current=bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	deferred=get(&ctx,&manager,"other",other_data)
	assert(ctx.frame_stats.material_reload_completed==completed+1 && len(ctx.material_reloads)==1)
	expect_color(current.albedo.texture,rl.WHITE);expect_color(deferred.albedo.texture,rl.GREEN)
	bridge.pump_material_jobs(&ctx);other=get(&ctx,&manager,"other",other_data)
	assert(ctx.frame_stats.material_reload_completed==completed+2 && len(ctx.material_reloads)==0);expect_color(other.albedo.texture,rl.YELLOW)
	validate_instanced_world_reload(&ctx,&manager,pool,root)
	validate_terrain_layer_reload(&ctx,&manager,pool,root)
	validate_manager_swap_reload(&ctx,&manager,&second_manager,pool,root)

	// Shutdown must wait for a real expensive accepted request before freeing
	// its owned data and the existing GPU material cache.
	heavy:=final_preview;heavy.procedural.resolution=1024;heavy.procedural.seed=97
	assert(assets.set_material_preview(&manager,"proc.material.json",heavy))
	bridge.material_from_path(&ctx,&manager,"proc.material.json",{255,255,255,255})
	assert(len(ctx.material_reloads)==1)
	shutdown_start:=time.tick_now();bridge.shutdown(&ctx)
	shutdown_ms:=time.duration_milliseconds(time.tick_since(shutdown_start))
	assert(!ctx.initialized && len(ctx.material_reloads)==0)
	serial,serial_ok:=bridge.init(root,128,128);assert(serial_ok);defer bridge.shutdown(&serial)
	serial_data:=solid_procedural(rl.RED)
	first:=get(&serial,&manager,"serial",serial_data);expect_color(first.albedo.texture,rl.RED)
	serial_data=solid_procedural(rl.BLUE)
	second:=get(&serial,&manager,"serial",serial_data)
	assert(second.albedo.texture.id!=first.albedo.texture.id && len(serial.material_reloads)==0)
	expect_color(second.albedo.texture,rl.BLUE)
	report:=struct {fixture_root,gpu,version:string,shutdown_drain_ms:f64,checks:[16]string}{root,string(gl.GetString(gl.RENDERER)),string(gl.GetString(gl.VERSION)),shutdown_ms,
		{"first loads synchronous","blocked pool retains old pixels","queue-full defers without inline generation","stale preview discarded","PNG/JPEG corrupt retention and repair with sRGB uploads","one install per pump","instanced World reload without manual getters","zero-admission queue retry through ordinary draw","stale completion retries latest preview through ordinary draw","generic async material diagnostic resolves on repair","synchronous bypass with an attached blocked pool","terrain layer atlas rebuild after GPU commit","terrain corruption retains packed atlas and repair resolves diagnostic","Asset_Manager swaps with colliding fingerprints and blocked old-manager work","shutdown drains accepted generation","nil-pool synchronous compatibility"}}
	bytes,marshal_error:=json.marshal(report,{pretty=true});assert(marshal_error==nil);defer delete(bytes)
	assert(os.write_entire_file("build/material_async_validation_report.json",bytes)==nil)
	fmt.printf("Material async GPU validation passed: synchronous first loads, bounded queue, immutable preview snapshots, stale discard, corrupt PNG/JPEG retention and repair, correct sRGB storage, one commit per pump, shutdown drain %.3f ms, nil-pool fallback. Fixtures: %s\n",shutdown_ms,root)
}

draw_world_pixel :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager) -> rl.Color {
	rl.BeginDrawing();defer rl.EndDrawing();rl.ClearBackground(rl.BLACK)
	assert(bridge.draw_scene(ctx,world,manager));rlgl.DrawRenderBatchActive()
	image:=rl.LoadImageFromScreen();assert(rl.IsImageValid(image));defer rl.UnloadImage(image)
	return rl.GetImageColor(image,64,64)
}

validate_instanced_world_reload :: proc(ctx: ^bridge.Context, manager: ^assets.Asset_Manager, pool: ^jobs.Pool, root: string) {
	assert(os.write_entire_file(fmt.tprintf("%s/world.material.json",root),`{"lighting":true,"filter":"point","mipmaps":false,"base_color":[255,255,255,255],"procedural":{"resolution":32,"color_a":[255,0,0,255],"color_b":[255,0,0,255]}}`)==nil)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	pose:=ecs.default_transform();pose.position={0,0,5}
	assert(ecs.add(&w,&r,camera,pose))
	assert(ecs.add(&w,&r,camera,ecs.Camera3D{active=true,target={0,0,0},up={0,1,0},fovy=45}))
	for x in ([2]f32{0,1.5}) {
		e:=ecs.create_entity(&w);pose=ecs.default_transform();pose.position={x,0,0}
		assert(ecs.add(&w,&r,e,pose))
		assert(ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube",material="world.material.json",color={255,255,255,255}}))
	}
	instancing:=ctx.instancing_enabled;ctx.instancing_enabled=true;defer {ctx.instancing_enabled=instancing}
	r3d.SetOutputMode(.ALBEDO);defer r3d.SetOutputMode(.SCENE)
	for _ in 0..<3 {draw_world_pixel(ctx,&w,manager)}
	red:=draw_world_pixel(ctx,&w,manager)
	fmt.printf("World fixture: center %v, instances %d, reused %v, material requests %d\n",red,ctx.frame_stats.prop_instances,ctx.frame_stats.prop_batches_reused,ctx.frame_stats.material_requests)
	assert(red.r>200 && red.b<20 && ctx.frame_stats.prop_instances==2 && ctx.frame_stats.prop_batches_reused,
		"the integration fixture must use a stationary reused instancing batch")
	old:=ctx.r3d_materials["world.material.json"].material.albedo.texture.id
	data,ok:=assets.material_data(manager,"world.material.json");assert(ok)
	data.procedural.color_a={0,0,255,255};data.procedural.color_b=data.procedural.color_a
	gate:Gate;hold(pool,&gate);defer release(&gate)
	assert(assets.set_material_preview(manager,"world.material.json",data))
	for _ in 0..<6 {
		busy:=draw_world_pixel(ctx,&w,manager)
		assert(busy.r>200 && busy.b<20 && ctx.r3d_materials["world.material.json"].material.albedo.texture.id==old)
	}
	assert(len(ctx.material_reloads)==1 && ctx.frame_stats.material_requests==0 && ctx.frame_stats.prop_batches_reused,
		"cached batches must stop requesting the material while its CPU work is still pending")
	release(&gate);wait_requests(ctx)
	blue:rl.Color
	for _ in 0..<8 {
		blue=draw_world_pixel(ctx,&w,manager)
		if ctx.r3d_materials["world.material.json"].material.albedo.texture.id!=old && blue.b>200 && blue.r<20 {break}
	}
	assert(ctx.r3d_materials["world.material.json"].material.albedo.texture.id!=old && blue.b>200 && blue.r<20,
		"ordinary draw_scene must wake the reused instancing cache and display the completed replacement")
	fmt.println("PASS ordinary World/instanced draw reload: stationary batch skips getters while busy, then publishes blue pixels after completion")

	// No material request is accepted in this case: a foreign job owns the only
	// worker and another foreign job occupies the only queue slot. A cached prop
	// batch must retry after pressure clears without any completion to wake it.
	queue_gate:Gate;hold(pool,&queue_gate);defer release(&queue_gate)
	fill_group:jobs.Group;fill_count:int
	assert(jobs.submit(pool,&fill_group,increment,&fill_count))
	data.procedural.color_a={0,255,0,255};data.procedural.color_b=data.procedural.color_a
	assert(assets.set_material_preview(manager,"world.material.json",data))
	blue_id:=ctx.r3d_materials["world.material.json"].material.albedo.texture.id
	rejections:int
	for _ in 0..<6 {
		busy:=draw_world_pixel(ctx,&w,manager);rejections+=ctx.frame_stats.material_reload_deferred
		assert(busy.b>200 && busy.r<20 && ctx.r3d_materials["world.material.json"].material.albedo.texture.id==blue_id && len(ctx.material_reloads)==0,
			"queue-full draws retain old pixels without admitting any material job")
	}
	assert(rejections>0)
	release(&queue_gate);jobs.wait(&fill_group);assert(fill_count==1)
	green:rl.Color
	for _ in 0..<10 {
		green=draw_world_pixel(ctx,&w,manager);wait_requests(ctx)
		if ctx.r3d_materials["world.material.json"].material.albedo.texture.id!=blue_id && green.g>200 && green.r<20 && green.b<20 {break}
	}
	assert(ctx.r3d_materials["world.material.json"].material.albedo.texture.id!=blue_id && green.g>200 && green.r<20 && green.b<20,
		"ordinary cached draws retry a zero-admission queue rejection after pressure clears")
	fmt.println("PASS ordinary World queue-full retry: no accepted material request while blocked, then green rendered pixels without manual getters")

	// Completion of A is obsolete, so discarding it must leave a wakeup for B.
	stale_gate:Gate;hold(pool,&stale_gate);defer release(&stale_gate)
	data.procedural.color_a={0,0,255,255};data.procedural.color_b=data.procedural.color_a
	assert(assets.set_material_preview(manager,"world.material.json",data))
	for _ in 0..<3 {draw_world_pixel(ctx,&w,manager)}
	assert(len(ctx.material_reloads)==1)
	data.procedural.color_a={255,0,0,255};data.procedural.color_b=data.procedural.color_a
	assert(assets.set_material_preview(manager,"world.material.json",data))
	for _ in 0..<3 {draw_world_pixel(ctx,&w,manager)}
	green_id:=ctx.r3d_materials["world.material.json"].material.albedo.texture.id
	release(&stale_gate);wait_requests(ctx)
	stale_pixel:=draw_world_pixel(ctx,&w,manager)
	assert(ctx.frame_stats.material_reload_discarded>0 && ctx.r3d_materials["world.material.json"].material.albedo.texture.id==green_id && stale_pixel.g>200 && stale_pixel.r<20 && stale_pixel.b<20,
		"an obsolete completion never publishes A's blue pixels")
	latest:rl.Color
	for _ in 0..<10 {
		latest=draw_world_pixel(ctx,&w,manager);wait_requests(ctx)
		if ctx.r3d_materials["world.material.json"].material.albedo.texture.id!=green_id && latest.r>200 && latest.b<20 && latest.g<20 {break}
	}
	assert(ctx.r3d_materials["world.material.json"].material.albedo.texture.id!=green_id && latest.r>200 && latest.b<20 && latest.g<20,
		"discarding A must let an ordinary cached draw queue and install B")
	fmt.println("PASS ordinary World stale completion: obsolete blue never installs, latest red preview retries without manual getters")

	// Editors can require an immediate replacement while keeping the shared
	// pool attached for other subsystems.
	bypass_gate:Gate;hold(pool,&bypass_gate);defer release(&bypass_gate)
	old_bypass:=ctx.material_reload_synchronous;ctx.material_reload_synchronous=true
	defer {ctx.material_reload_synchronous=old_bypass}
	data.procedural.color_a={0,0,255,255};data.procedural.color_b=data.procedural.color_a
	assert(assets.set_material_preview(manager,"world.material.json",data))
	immediate:=draw_world_pixel(ctx,&w,manager)
	assert(immediate.b>200 && immediate.r<20 && immediate.g<20 && len(ctx.material_reloads)==0 && ctx.worker_pool==pool,
		"the synchronous material bypass installs immediately with a blocked pool still attached")
	ctx.material_reload_synchronous=old_bypass;release(&bypass_gate)
	fmt.println("PASS ordinary World synchronous bypass with an attached blocked pool")
}

validate_terrain_layer_reload :: proc(ctx: ^bridge.Context, manager: ^assets.Asset_Manager, pool: ^jobs.Pool, root: string) {
	write_image(fmt.tprintf("%s/layer.png",root),{255,0,0,255})
	assert(os.write_entire_file(fmt.tprintf("%s/layer.material.json",root),`{"texture":"layer.png","filter":"point","mipmaps":false,"lighting":true,"base_color":[255,255,255,255]}`)==nil)
	assert(os.write_entire_file(fmt.tprintf("%s/base.material.json",root),`{"lighting":true,"base_color":[255,255,255,255]}`)==nil)
	heights:[8]u8;assert(os.write_entire_file(fmt.tprintf("%s/flat.r16",root),heights[:])==nil)
	d:=terrain.default_description();d.heightmap="flat.r16";d.resolution={2,2};d.size={4,4};d.height_scale=0;d.material="base.material.json"
	layers:=[1]terrain.Layer{terrain.default_layer()};layers[0].material="layer.material.json";d.layers=layers[:]
	bytes,error:=json.marshal(d);assert(error==nil);defer delete(bytes)
	assert(os.write_entire_file(fmt.tprintf("%s/flat.terrain.json",root),bytes)==nil)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w);pose:=ecs.default_transform();pose.position={2,5,2}
	assert(ecs.add(&w,&r,camera,pose))
	assert(ecs.add(&w,&r,camera,ecs.Camera3D{active=true,target={2,0,2},up={0,0,-1},fovy=45}))
	e:=ecs.create_entity(&w);assert(ecs.add(&w,&r,e,ecs.default_transform()))
	component:=ecs.default_terrain();component.asset="flat.terrain.json";assert(ecs.add(&w,&r,e,component))
	ecs.sync_terrains(&w,manager)
	r3d.SetOutputMode(.ALBEDO);defer r3d.SetOutputMode(.SCENE)
	for _ in 0..<3 {draw_world_pixel(ctx,&w,manager)}
	red:=draw_world_pixel(ctx,&w,manager);assert(red.r>200 && red.b<20)
	old_layer:=ctx.terrain_layers["layer.material.json"]
	old_set:=ctx.terrains[e].layer_set.atlases[0].id
	old_material:=ctx.r3d_materials["layer.material.json"].material.albedo.texture.id
	old_signature:=ctx.r3d_materials["layer.material.json"].signature
	mesh_revision:=ctx.terrains[e].revision
	gate:Gate;hold(pool,&gate);defer release(&gate)
	write_image(fmt.tprintf("%s/layer.png",root),{0,0,255,255});invalidate_source(manager,"layer.png")
	for _ in 0..<6 {
		busy:=draw_world_pixel(ctx,&w,manager)
		assert(busy.r>200 && busy.b<20 && ctx.r3d_materials["layer.material.json"].material.albedo.texture.id==old_material)
	}
	assert(len(ctx.material_reloads)==1)
	release(&gate);wait_requests(ctx)
	blue:rl.Color
	for _ in 0..<8 {
		blue=draw_world_pixel(ctx,&w,manager)
		if ctx.r3d_materials["layer.material.json"].material.albedo.texture.id!=old_material && blue.b>200 && blue.r<20 {break}
	}
	updated:=ctx.terrain_layers["layer.material.json"]
	assert(ctx.r3d_materials["layer.material.json"].signature==old_signature && updated.texture.id!=old_layer.texture.id && ctx.terrains[e].layer_set.atlases[0].id!=old_set,
		"GPU completion must replace layer and packed atlases even though the authored material hash is unchanged")
	assert(blue.b>200 && blue.r<20 && ctx.terrains[e].revision==mesh_revision && ctx.frame_stats.terrain_chunks_built==0,
		"the terrain displays new texture pixels without a terrain/mesh rebuild")
	fmt.println("PASS ordinary terrain draw reload: unchanged material data hash, async GPU commit refreshes layer/packed atlases and rendered pixels")

	// Source polling and failed jobs must not replace either atlas with copies
	// of the old material; only a successful install advances their identity.
	blue_layer:=updated.texture.id;blue_set:=ctx.terrains[e].layer_set.atlases[0].id
	corrupt_gate:Gate;hold(pool,&corrupt_gate);defer release(&corrupt_gate)
	assert(os.write_entire_file(fmt.tprintf("%s/layer.png",root),"invalid terrain layer replacement")==nil)
	invalidate_source(manager,"layer.png")
	for _ in 0..<5 {
		busy:=draw_world_pixel(ctx,&w,manager)
		assert(busy.b>200 && busy.r<20 && ctx.terrain_layers["layer.material.json"].texture.id==blue_layer && ctx.terrains[e].layer_set.atlases[0].id==blue_set,
			"pending layer decoding preserves the existing layer and packed atlas handles")
	}
	release(&corrupt_gate);wait_requests(ctx)
	failed:=draw_world_pixel(ctx,&w,manager)
	assert(failed.b>200 && failed.r<20 && ctx.terrain_layers["layer.material.json"].texture.id==blue_layer && ctx.terrains[e].layer_set.atlases[0].id==blue_set,
		"failed layer decoding retains the existing atlas identities and blue rendered pixels")
	failure_key:=assets.diagnostic_key("layer.material.json","material","layer.material.json");defer delete(failure_key)
	assert(manager.diagnostics.reported[failure_key])
	write_image(fmt.tprintf("%s/layer.png",root),{0,255,0,255});invalidate_source(manager,"layer.png")
	green:rl.Color
	for _ in 0..<10 {
		green=draw_world_pixel(ctx,&w,manager);wait_requests(ctx)
		if green.g>200 && green.r<20 && green.b<20 {break}
	}
	assert(green.g>200 && green.r<20 && green.b<20 && ctx.terrain_layers["layer.material.json"].texture.id!=blue_layer &&
		ctx.terrains[e].layer_set.atlases[0].id!=blue_set && !manager.diagnostics.reported[failure_key],
		"a repaired successful layer install refreshes both atlases, displays green, and clears its generic diagnostic")
	fmt.println("PASS ordinary terrain corruption/repair: pending and failed work retain atlas identities; repaired green install resolves diagnostic")
}

validate_direct_repair :: proc(ctx: ^bridge.Context, manager: ^assets.Asset_Manager, key: string, data: assets.Material_Data,
	file,relative: string, color: rl.Color, jpeg: bool) {
	before:=get(ctx,manager,key,data);before_color:=pixel(before.albedo.texture)
	assert(os.write_entire_file(file,"invalid image replacement")==nil);invalidate_source(manager,relative)
	bridge.pump_material_jobs(ctx)
	pending:=get(ctx,manager,key,data);assert(pending.albedo.texture.id==before.albedo.texture.id)
	wait_requests(ctx);bridge.pump_material_jobs(ctx)
	retained:=get(ctx,manager,key,data)
	assert(retained.albedo.texture.id==before.albedo.texture.id && pixel(retained.albedo.texture)==before_color)
	failure_key:=assets.diagnostic_key(key,"material",key);defer delete(failure_key)
	assert(manager.diagnostics.reported[failure_key],"an asynchronous decode failure records the generic material diagnostic")
	started:=ctx.frame_stats.material_reload_started
	get(ctx,manager,key,data);assert(ctx.frame_stats.material_reload_started==started,"an unchanged invalid source is not retried")
	write_image(file,color,jpeg);invalidate_source(manager,relative)
	get(ctx,manager,key,data);wait_requests(ctx);bridge.pump_material_jobs(ctx)
	repaired:=get(ctx,manager,key,data)
	assert(repaired.albedo.texture.id!=before.albedo.texture.id)
	expect_color(repaired.albedo.texture,color,4 if jpeg else 0);expect_srgb(repaired.albedo.texture,!jpeg)
	assert(!manager.diagnostics.reported[failure_key],"a repaired successful GPU commit resolves the generic asynchronous material diagnostic")
}

validate_manager_swap_reload :: proc(ctx: ^bridge.Context, a,b: ^assets.Asset_Manager, pool: ^jobs.Pool, root: string) {
	path:="swap.material.json"
	image_path:=fmt.tprintf("%s/swap.png",root)
	write_image(image_path,{255,0,0,255})
	assert(os.write_entire_file(fmt.tprintf("%s/%s",root,path),`{"texture":"swap.png","lighting":true,"filter":"point","mipmaps":false,"base_color":[255,255,255,255]}`)==nil)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w);pose:=ecs.default_transform();pose.position={0,0,5}
	assert(ecs.add(&w,&r,camera,pose))
	assert(ecs.add(&w,&r,camera,ecs.Camera3D{active=true,target={0,0,0},up={0,1,0},fovy=45}))
	for x in ([2]f32{0,1.5}) {
		e:=ecs.create_entity(&w);pose=ecs.default_transform();pose.position={x,0,0}
		assert(ecs.add(&w,&r,e,pose))
		assert(ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube",material=path,color={255,255,255,255}}))
	}
	instancing:=ctx.instancing_enabled;ctx.instancing_enabled=true;defer {ctx.instancing_enabled=instancing}
	r3d.SetOutputMode(.ALBEDO);defer r3d.SetOutputMode(.SCENE)
	for _ in 0..<3 {draw_world_pixel(ctx,&w,a)}
	red:=draw_world_pixel(ctx,&w,a);assert(red.r>200 && red.g<20 && red.b<20 && ctx.frame_stats.prop_batches_reused)
	red_id:=ctx.r3d_materials[path].material.albedo.texture.id
	a_data,a_ok:=assets.material_data(a,path);assert(a_ok)
	// A keeps its already-observed generation and installed red GPU source.
	// Fresh B observes blue at generation one: authored data, path revision and
	// dependency fingerprints intentionally collide despite different pixels.
	write_image(image_path,{0,0,255,255})
	b_data,b_ok:=assets.material_data(b,path);assert(b_ok)
	assert(assets.material_data_signature(a_data)==assets.material_data_signature(b_data) &&
		assets.material_dependency_fingerprint(a,path,a_data)==assets.material_dependency_fingerprint(b,path,b_data) &&
		assets.material_path_revision(a,path)==assets.material_path_revision(b,path),
		"the manager-swap fixture must collide in authored data, fingerprint and path revision")
	first_b:=draw_world_pixel(ctx,&w,b)
	assert(first_b.r>200 && first_b.b<20 && ctx.r3d_materials[path].source_manager==a && len(ctx.material_reloads)==1 && ctx.material_reloads[path].manager==b,
		"a colliding fresh manager queues its own source without claiming the old deferred cache")
	wait_requests(ctx)
	blue:rl.Color
	for _ in 0..<10 {
		blue=draw_world_pixel(ctx,&w,b);wait_requests(ctx)
		if ctx.r3d_materials[path].source_manager==b && blue.b>200 && blue.r<20 {break}
	}
	assert(ctx.r3d_materials[path].source_manager==b && ctx.r3d_materials[path].material.albedo.texture.id!=red_id && blue.b>200 && blue.r<20,
		"manager identity prevents equal fingerprint/path versions from reusing the other manager's GPU pixels")

	// Install A's green preview, then accept A's blocked blue request. B becomes
	// the active draw owner with a red preview while A still owns that request.
	green_data:=solid_procedural({0,255,0,255});assert(assets.set_material_preview(a,path,green_data))
	green:rl.Color
	for _ in 0..<10 {
		green=draw_world_pixel(ctx,&w,a);wait_requests(ctx)
		if ctx.r3d_materials[path].source_manager==a && green.g>200 && green.r<20 && green.b<20 {break}
	}
	assert(ctx.r3d_materials[path].source_manager==a && green.g>200 && green.r<20 && green.b<20)
	green_id:=ctx.r3d_materials[path].material.albedo.texture.id
	gate:Gate;hold(pool,&gate);defer release(&gate)
	a_blue:=solid_procedural({0,0,255,255});assert(assets.set_material_preview(a,path,a_blue))
	for _ in 0..<4 {draw_world_pixel(ctx,&w,a)}
	assert(len(ctx.material_reloads)==1 && ctx.material_reloads[path].manager==a)
	b_red:=solid_procedural({255,0,0,255});assert(assets.set_material_preview(b,path,b_red))
	for _ in 0..<5 {
		busy:=draw_world_pixel(ctx,&w,b)
		assert(busy.g>200 && busy.r<20 && busy.b<20 && ctx.r3d_materials[path].source_manager==a &&
			ctx.r3d_materials[path].material.albedo.texture.id==green_id && ctx.material_reloads[path].manager==a,
			"deferred B draws retain both A's last-good ownership and A's accepted blocked request")
	}
	release(&gate);wait_requests(ctx)
	latest:rl.Color
	for _ in 0..<12 {
		latest=draw_world_pixel(ctx,&w,b);wait_requests(ctx)
		assert(latest.b<20,"A's obsolete blue completion cannot install while B owns the active view")
		if ctx.r3d_materials[path].source_manager==b && latest.r>200 && latest.g<20 {break}
	}
	assert(ctx.r3d_materials[path].source_manager==b && latest.r>200 && latest.g<20 && latest.b<20 && len(ctx.material_reloads)==0,
		"B retries and installs through ordinary cached draws even though the completed old request belonged to A")
	fmt.println("PASS ordinary World manager swaps: colliding data/fingerprint/version uses new GPU source; blocked A completion cannot starve active B preview")
}
