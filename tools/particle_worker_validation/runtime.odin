package main

import "core:fmt"
import "core:mem"
import "core:os"
import "rune:assets"
import rune "rune:core"
import "rune:ecs"
import "rune:jobs"
import "rune:particles"
import "rune:render"
import bridge "rune:r3d_bridge"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

Core_Probe :: struct {
	serial:ecs.World,
	serial_entities,entities:[Emitters]ecs.Entity,
	frames:int,
	target:rl.RenderTexture2D,
}
core_probe:^Core_Probe

core_update :: proc(game:^rune.Engine,world:^ecs.World) {
	assert(game.worker_pool!=nil)
	if core_probe.frames==0 {
		live:=0;for entity in core_probe.entities {live+=ecs.particle_count_2d(world,entity)}
		assert(live>=particles.Particle_Parallel_Min_Work_2D,"the normal engine path starts at the production dispatch gate")
	}
	ecs.update_particles_2d(&core_probe.serial,game.delta_time)
}
capture_2d :: proc(world:^ecs.World,manager:^assets.Asset_Manager,target:rl.RenderTexture2D) -> (u64,int) {
	rl.BeginTextureMode(target);rl.ClearBackground(rl.BLACK)
	assert(render.draw_scene_2d(world,manager));rl.EndTextureMode()
	image:=rl.LoadImageFromTexture(target.texture);defer rl.UnloadImage(image)
	return image_hash(image)
}
core_draw :: proc(game:^rune.Engine,world:^ecs.World) {
	compare_emitters(&core_probe.serial,world,core_probe.serial_entities,core_probe.entities)
	serial,visible:=capture_2d(&core_probe.serial,&game.assets,core_probe.target)
	parallel,_:=capture_2d(world,&game.assets,core_probe.target)
	assert(serial==parallel && visible>20,"engine-owned worker simulation produces the exact scalar circle/texture/blend pixels")
	core_probe.frames+=1
	if core_probe.frames==6 {rune.request_exit(game)}
}

validate_core_runtime :: proc() {
	root,error:=os.make_directory_temp("build","particle-core-workers-*",context.allocator);assert(error==nil);defer delete(root)
	project:=fmt.aprintf("%s/project.json",root);defer delete(project)
	texture:=fmt.aprintf("%s/soft.png",root);defer delete(texture)
	assert(os.write_entire_file(project,`{"name":"Particle workers","window":{"width":256,"height":256,"hidden":true,"target_fps":60},"jobs":{"worker_count":3,"queue_capacity":1}}`)==nil)
	game,ok:=rune.init(project);assert(ok)
	image:=rl.GenImageGradientRadial(16,16,0,rl.WHITE,{255,255,255,0});assert(rl.ExportImage(image,fmt.ctprintf("%s",texture)));rl.UnloadImage(image)
	probe:Core_Probe
	probe.serial,probe.serial_entities=emitter_world(&game.registry,"soft.png");defer ecs.destroy(&probe.serial)
	world,entities:=emitter_world(&game.registry,"soft.png");probe.entities=entities
	probe.target=rl.LoadRenderTexture(256,256);assert(rl.IsRenderTextureValid(probe.target))
	core_probe=&probe;defer {core_probe=nil}
	assert(rune.register_system(&game,{name="particle-worker-regression",update=core_update,draw=core_draw}))
	// run_scene owns world and engine shutdown. Release the GL fixture from a
	// system shutdown callback, before that window closes.
	assert(rune.register_system(&game,{name="particle-worker-target",shutdown=proc(game:^rune.Engine,world:^ecs.World) {rl.UnloadRenderTexture(core_probe.target)}}))
	rune.run_scene(&game,&world)
	assert(probe.frames==6 && !game.is_running && game.worker_pool==nil)
	fmt.println("PASS engine 2D worker simulation and exact circle/textured alpha/additive render parity across six frames")
}

validate_gpu_streams :: proc(state:^bridge.Particle_Billboard_Batch) {
	count:=len(state.positions);assert(count>0 && state.buffer.capacity>=i32(count))
	previous:i32;gl.GetIntegerv(gl.ARRAY_BUFFER_BINDING,&previous)
	defer gl.BindBuffer(gl.ARRAY_BUFFER,u32(previous))
	positions:=make([]rl.Vector3,count,context.temp_allocator)
	scales:=make([]rl.Vector3,count,context.temp_allocator)
	colors:=make([]rl.Color,count,context.temp_allocator)
	gl.BindBuffer(gl.ARRAY_BUFFER,state.buffer.buffers[0]);gl.GetBufferSubData(gl.ARRAY_BUFFER,0,count*size_of(rl.Vector3),raw_data(positions))
	gl.BindBuffer(gl.ARRAY_BUFFER,state.buffer.buffers[2]);gl.GetBufferSubData(gl.ARRAY_BUFFER,0,count*size_of(rl.Vector3),raw_data(scales))
	gl.BindBuffer(gl.ARRAY_BUFFER,state.buffer.buffers[3]);gl.GetBufferSubData(gl.ARRAY_BUFFER,0,count*size_of(rl.Color),raw_data(colors))
	assert(hash_bytes(mem.slice_to_bytes(positions))==hash_bytes(mem.slice_to_bytes(state.positions[:])) &&
		hash_bytes(mem.slice_to_bytes(scales))==hash_bytes(mem.slice_to_bytes(state.scales[:])) &&
		hash_bytes(mem.slice_to_bytes(colors))==hash_bytes(mem.slice_to_bytes(state.colors[:])),"actual GPU POSITION/SCALE/COLOR buffers match the prepared streams")
}

capture_3d :: proc(ctx:^bridge.Context,world:^ecs.World,manager:^assets.Asset_Manager,batches:[]bridge.Particle3D_Batch) -> (u64,int) {
	rl.BeginDrawing();rl.ClearBackground(rl.BLACK)
	assert(bridge.draw_scene_ex(ctx,world,manager,{particle_batches=batches,background_color={0,0,0,255},material_time_override=true}))
	rlgl.DrawRenderBatchActive()
	image:=rl.LoadImageFromScreen();defer rl.UnloadImage(image)
	hash,visible:=image_hash(image)
	rl.EndDrawing()
	return hash,visible
}

Billboard_Runtime_Busy :: struct {ctx:^bridge.Context,world:^ecs.World,manager:^assets.Asset_Manager,batches:[]bridge.Particle3D_Batch,expected:u64}
billboard_runtime_busy :: proc(pool:^jobs.Pool,data:rawptr) {
	busy:=(^Billboard_Runtime_Busy)(data);previous:=busy.ctx.worker_pool;busy.ctx.worker_pool=pool;defer {busy.ctx.worker_pool=previous}
	hash,visible:=capture_3d(busy.ctx,busy.world,busy.manager,busy.batches)
	assert(hash==busy.expected && visible>100 && busy.ctx.frame_stats.particle_prepare_job_batches==2)
}

validate_billboard_runtime :: proc(pool:^jobs.Pool) {
	rl.SetConfigFlags({.WINDOW_HIDDEN});rl.InitWindow(256,256,"Particle worker GPU validation");defer rl.CloseWindow()
	gl.load_up_to(3,3,proc(pointer:rawptr,name:cstring) {(^rawptr)(pointer)^=rlgl.GetProcAddress(name)})
	root,error:=os.make_directory_temp("build","particle-billboard-workers-*",context.allocator);assert(error==nil);defer delete(root)
	assert(os.write_entire_file(fmt.tprintf("%s/particle.material.json",root),`{"lighting":true,"base_color":[25,25,25,255],"emission_color":[255,255,255,255],"emission_energy":1.5,"roughness":1}`)==nil)
	manager:=assets.init(root);defer assets.shutdown(&manager)
	ctx,ok:=bridge.init(root,256,256);assert(ok);defer bridge.shutdown(&ctx)
	registry:=ecs.init_registry();defer ecs.destroy_registry(&registry);assert(ecs.register_builtin_components(&registry))
	world:=ecs.init();defer ecs.destroy(&world)
	camera_entity:=ecs.create_entity(&world)
	assert(ecs.add(&world,&registry,camera_entity,ecs.Transform{position={0,0,12},scale={1,1,1}}))
	assert(ecs.add(&world,&registry,camera_entity,ecs.Camera3D{active=true,target={0,0,0},up={0,1,0},fovy=45}))
	live:=particle_fixture(Billboard_Count);defer delete(live)
	original:=hash_bytes(mem.slice_to_bytes(live))
	batches:=[4]bridge.Particle3D_Batch{
		{particles=live[:Billboard_Count],material="particle.material.json",shape=.Billboard,blend=.Alpha},
		{particles=live[:Billboard_Count-127],material="particle.material.json",shape=.Billboard,blend=.Additive},
		{particles=live[:Billboard_Count-511],material="particle.material.json",shape=.Billboard,blend=.Alpha},
		{particles=live[7:12],material="particle.material.json",shape=.Sphere,blend=.Additive},
	}
	serial:[3]bridge.Particle_Billboard_Batch;defer {for &state in serial {release_prepared(&state)}}
	buffer_ids:[3]u32
	for stage in 0..<5 {
		if stage==1 {batches[0].blend=.Additive;batches[1].blend=.Alpha}
		if stage==2 {pose,_:=ecs.get_transform(&world,camera_entity);pose.position={12,3,0};assert(ecs.set_transform(&world,camera_entity,pose))}
		if stage==3 {for &batch in batches {batch.particles=nil}}
		if stage==4 {for &batch,index in batches {batch.particles=live[:Billboard_Count-index*127] if index<3 else live[7:12]}}
		camera:=rl.Camera3D{position={12,3,0} if stage>=2 else {0,0,12},target={0,0,0},up={0,1,0},fovy=45}
		for &state,index in serial {bridge.prepare_particle_billboards(&state,batches[index],camera)}
		ctx.worker_pool=nil
		expected,visible:=capture_3d(&ctx,&world,&manager,batches[:])
		assert(ctx.frame_stats.particle_prepare_job_batches==0)
		ctx.worker_pool=pool
		actual,other_visible:=capture_3d(&ctx,&world,&manager,batches[:])
		assert(expected==actual && visible==other_visible,"ordinary scalar and worker draws produce identical pixels across shapes, blend modes and camera turns")
		if stage==3 {
			assert(ctx.frame_stats.instance_uploads==0 && ctx.frame_stats.particle_billboards_prepared==0 && ctx.frame_stats.particle_prepare_job_batches==0,"empty draws upload no stale data")
			continue
		}
		assert(visible>100 && ctx.frame_stats.particle_prepare_job_batches==2 && ctx.frame_stats.instance_uploads==9)
		for &state,index in serial {
			data:=&ctx.particle_billboards.batches[index]
			compare_prepared(&state,data);validate_gpu_streams(data)
			if stage==0 {buffer_ids[index]=data.buffer.buffers[0]}
			else {assert(buffer_ids[index]==data.buffer.buffers[0],"mode/camera/empty transitions reuse their batch's GPU buffers")}
			for prior in 0..<index {assert(data.buffer.buffers[0]!=ctx.particle_billboards.batches[prior].buffer.buffers[0],"multiple deferred draws retain distinct live instance buffers")}
		}
		assert(hash_bytes(mem.slice_to_bytes(live))==original,"actual rendering never changes the borrowed simulation")
		if stage==0 {
			busy:=Billboard_Runtime_Busy{&ctx,&world,&manager,batches[:],expected}
			for full in ([2]bool{false,true}) {with_busy_pool(full,billboard_runtime_busy,&busy)}
		}
	}
	ctx.worker_pool=nil
	mask:=ctx.particle_billboards.texture.id
	bridge.shutdown(&ctx)
	assert(!ctx.initialized && len(ctx.particle_billboards.batches)==0 && !gl.IsTexture(mask),"bridge shutdown releases the radial mask and retained batch storage before the window closes")
	for buffer in buffer_ids {assert(!gl.IsBuffer(buffer),"bridge shutdown releases every live particle instance buffer")}
	fmt.println("PASS billboard GPU streams and exact scalar/worker pixels: three distinct batches, alpha/additive, spheres, camera turn, empty reuse, full/free queue fallback and GPU shutdown")
}
