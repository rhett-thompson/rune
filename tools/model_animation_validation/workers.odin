package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "rune:assets"
import "rune:ecs"
import "rune:jobs"
import bridge "rune:r3d_bridge"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import r3d "r3d:r3d"

Worker_Actors :: 48 // 2496 FBX bones exceed the common 2048-bone cutoff.
Worker_Checkpoints :: 20
Worker_Punch :: "../assets/Punching.fbx"
Worker_Markers :: "../../build/model-animation-worker-markers.model-events.json"

Worker_Actor_Snapshot :: struct {
	state: ecs.Model_Animation_State,
	exists, ready: bool,
	clip: i32,
	pose_time, blend_elapsed, blend_duration: f32,
	local, model, blend, skin, uploaded, native_states, events: u64,
	event_count: int,
}
Worker_Snapshot :: struct {
	actors: [Worker_Actors]Worker_Actor_Snapshot,
	players, bones: int,
}

worker_hash_u32 :: proc(hash: ^u64, value: u32) {
	for shift in 0..<4 {hash^=(hash^ ~ u64((value >> u32(shift*8)) & 255))*1099511628211}
}
worker_hash_f32 :: proc(hash: ^u64, value: f32) {worker_hash_u32(hash,transmute(u32)value)}
worker_hash_string :: proc(hash: ^u64, value: string) {
	worker_hash_u32(hash,u32(len(value)))
	for byte in transmute([]u8)value {hash^=(hash^ ~ u64(byte))*1099511628211}
}
worker_pose_hash :: proc(pose: []rl.Matrix) -> u64 {
	hash:=u64(14695981039346656037)
	for transform in pose {for column in 0..<4 {for row in 0..<4 {worker_hash_f32(&hash,transform[row,column])}}}
	return hash
}

// R3D uploads each player's skin matrices into a GL_RGBA16F one-dimensional
// texture. Reading that texture verifies the owner upload, not merely CPU pose
// parity. Preserve the owner's GL bindings around the diagnostic readback.
worker_uploaded_hash :: proc(player:r3d.AnimationPlayer) -> u64 {
	previous_active,previous_binding:i32
	gl.GetIntegerv(gl.ACTIVE_TEXTURE,&previous_active)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.GetIntegerv(gl.TEXTURE_BINDING_1D,&previous_binding)
	gl.BindTexture(gl.TEXTURE_1D,player.skinTexture)
	values:=make([]f32,int(player.skeleton.boneCount)*16,context.temp_allocator)
	gl.GetTexImage(gl.TEXTURE_1D,0,gl.RGBA,gl.FLOAT,raw_data(values))
	gl.BindTexture(gl.TEXTURE_1D,u32(previous_binding))
	gl.ActiveTexture(u32(previous_active))
	hash:=u64(14695981039346656037)
	for value,index in values {
		expected:=(cast([^]f32)player.skinBuffer)[index]
		assert(math.abs(value-expected)<=max(f32(0.002),math.abs(expected)*0.0015),"GPU skin texture matches the CPU upload within half-float precision")
		worker_hash_f32(&hash,value)
	}
	return hash
}

worker_snapshot :: proc(ctx:^bridge.Context,world:^ecs.World,actors:[Worker_Actors]ecs.Entity) -> Worker_Snapshot {
	result:Worker_Snapshot
	result.players,result.bones=ctx.animation_stats.players_evaluated,ctx.animation_stats.bones_evaluated
	assert(!ecs.model_animation_events_overflowed(world))
	for entity,index in actors {
		item:=&result.actors[index]
		item.state,item.exists=ecs.get_model_animation_state(world,entity)
		cached,found:=ctx.animation_players[entity]
		item.ready=found && cached.ready
		if item.ready {
			player:=cached.player
			item.clip, item.pose_time=player.activeAnimIndex,cached.pose_time
			item.blend_elapsed,item.blend_duration=cached.blend_elapsed,cached.blend_duration
			count:=int(player.skeleton.boneCount)
			item.local=worker_pose_hash(player.localPose[:count])
			item.model=worker_pose_hash(player.modelPose[:count])
			item.blend=worker_pose_hash(cached.blend_pose)
			item.skin=worker_pose_hash(player.skinBuffer[:count])
			item.uploaded=worker_uploaded_hash(player)
			item.native_states=14695981039346656037
			for native in player.states[:player.animLib.count] {
				worker_hash_f32(&item.native_states,native.currentTime)
				worker_hash_f32(&item.native_states,native.speed)
				worker_hash_u32(&item.native_states,u32(native.play))
				worker_hash_u32(&item.native_states,u32(native.loop))
			}
			asset:=ctx.models[cached.path]
			assert(player.skeleton.bones==asset.model.skeleton.bones && player.animLib.animations==asset.animations.animations,"players refer to the current post-preflight resources")
		}
		// Entity handles differ between fresh Worlds. Compare marker order per
		// actor while retaining the order of simultaneous markers on that actor.
		item.events=14695981039346656037
		for event in ecs.model_animation_events(world) {
			if event.entity!=entity {continue}
			worker_hash_string(&item.events,event.model);worker_hash_string(&item.events,event.clip);worker_hash_string(&item.events,event.name)
			worker_hash_f32(&item.events,event.time);worker_hash_u32(&item.events,u32(event.reverse));item.event_count+=1
		}
	}
	return result
}

worker_world :: proc(registry:^ecs.Component_Registry) -> (ecs.World,[Worker_Actors]ecs.Entity) {
	world:=ecs.init()
	actors:[Worker_Actors]ecs.Entity
	camera:=ecs.create_entity(&world)
	assert(ecs.add(&world,registry,camera,ecs.Transform{position={10,8,20},scale={1,1,1}}))
	assert(ecs.add(&world,registry,camera,ecs.Camera3D{target={6,1,6},up={0,1,0},fovy=45,active=true}))
	for &entity,index in actors {
		entity=ecs.create_entity(&world)
		assert(ecs.add(&world,registry,entity,ecs.Transform{position={f32(index%8)*1.7,0,f32(index/8)*2},scale={0.01,0.01,0.01}}))
		assert(ecs.add(&world,registry,entity,ecs.ModelRenderer{model=Strut,tint={255,255,255,255},material="assets/materials/strut.material.json"}))
		assert(ecs.add(&world,registry,entity,ecs.ModelAnimator{clip="mixamo.com",events=Worker_Markers,speed=f32(index%4+1)*0.5,loop=true,autoplay=true}))
	}
	return world,actors
}

worker_pause :: proc(world:^ecs.World,actors:[Worker_Actors]ecs.Entity,pause:bool) {
	for entity in actors {
		if pause {assert(ecs.pause_model_animation(world,entity))} else {assert(ecs.resume_model_animation(world,entity))}
	}
}

worker_draw :: proc(ctx:^bridge.Context,world:^ecs.World,manager:^assets.Asset_Manager,capture:bool=false) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	assert(bridge.draw_scene(ctx,world,manager))
	if capture {
		rlgl.DrawRenderBatchActive()
		image:=rl.LoadImageFromScreen();assert(image.data!=nil)
		defer rl.UnloadImage(image)
		colors:=rl.LoadImageColors(image);defer rl.UnloadImageColors(colors)
		visible:=0
		for pixel in colors[:int(image.width*image.height)] {if pixel.r>40 || pixel.g>40 || pixel.b>40 {visible+=1}}
		assert(visible>100,"ordinary draw renders the animated crowd")
	}
	rl.EndDrawing()
}

Worker_Gate :: struct {started,release:sync.Sema}
worker_hold :: proc(data:rawptr) {gate:=(^Worker_Gate)(data);sync.sema_post(&gate.started);sync.sema_wait(&gate.release)}
worker_increment :: proc(data:rawptr) {(^int)(data)^+=1}
Worker_Watchdog :: struct {finished:sync.Sema,gate:^Worker_Gate,expired:bool}
worker_watchdog :: proc(watch_thread:^thread.Thread) {
	watch:=(^Worker_Watchdog)(watch_thread.data)
	if !sync.sema_wait_with_timeout(&watch.finished,2*time.Second) {watch.expired=true;sync.sema_post(&watch.gate.release)}
}

worker_busy_update :: proc(ctx:^bridge.Context,world:^ecs.World,manager:^assets.Asset_Manager,full:bool) {
	pool:=jobs.create(1,1);assert(pool!=nil);defer jobs.destroy(pool)
	previous:=ctx.worker_pool;ctx.worker_pool=pool;defer {ctx.worker_pool=previous}
	gate:Worker_Gate;hold_group,fill_group:jobs.Group;fill_count:int
	assert(jobs.submit(pool,&hold_group,worker_hold,&gate))
	assert(sync.sema_wait_with_timeout(&gate.started,2*time.Second))
	if full {assert(jobs.submit(pool,&fill_group,worker_increment,&fill_count))}
	watch:=Worker_Watchdog{gate=&gate}
	watch_thread:=thread.create(worker_watchdog);assert(watch_thread!=nil)
	watch_thread.data=&watch;thread.start(watch_thread)
	bridge.update_animations(ctx,world,manager,0.05)
	sync.sema_post(&watch.finished);thread.destroy(watch_thread)
	assert(!watch.expired,"animation update returns with an unrelated worker blocked, with either a full or free queue")
	assert(ctx.animation_stats.job_batches==1 && !jobs.is_complete(&hold_group))
	assert(fill_count==0,"caller participation never executes unrelated queued jobs inline")
	sync.sema_post(&gate.release);jobs.wait(&hold_group);jobs.wait(&fill_group)
	assert(!full || fill_count==1)
}

worker_pass :: proc(ctx:^bridge.Context,manager:^assets.Asset_Manager,registry:^ecs.Component_Registry,pool:^jobs.Pool,expected:^[Worker_Checkpoints]Worker_Snapshot,parallel:bool) {
	ctx.worker_pool=pool
	world,actors:=worker_world(registry)
	defer ecs.destroy(&world)
	for checkpoint in 0..<Worker_Checkpoints {
		dt:=f32(0)
		switch checkpoint {
		case 0:
		case 1: dt=0.25
		case 2: worker_pause(&world,actors,true);dt=0.75
		case 3:
			before:=worker_snapshot(ctx,&world,actors)
			for _ in 0..<3 {worker_draw(ctx,&world,manager,capture=true)}
			after:=worker_snapshot(ctx,&world,actors)
			assert(before.actors==after.actors && after.players==0 && after.bones==0,"paused repeated draws perform no pose work and do not publish timeline or marker changes")
		case 4:
			worker_pause(&world,actors,false)
			for index in 0..<2 {
				animator,_:=ecs.get_model_animator(&world,actors[index]);animator.loop=false;animator.speed=1 if index==0 else -1
				assert(ecs.set_model_animator(&world,actors[index],animator))
				assert(ecs.play_model_animation(&world,actors[index],"worker_punch"))
			}
			dt=0.2
		case 5: dt=2
		case 6:
			for entity,index in actors {
				animator,_:=ecs.get_model_animator(&world,entity);animator.speed=1;animator.loop=true
				assert(ecs.set_model_animator(&world,entity,animator))
				assert(ecs.transition_model_animation(&world,entity,"mixamo.com" if index<2 else "worker_punch",0.4))
			}
		case 7: dt=0.15
		case 8: worker_pause(&world,actors,true);dt=0.7
		case 9:
			before:=worker_snapshot(ctx,&world,actors)
			for _ in 0..<2 {worker_draw(ctx,&world,manager)}
			assert(before.actors==worker_snapshot(ctx,&world,actors).actors,"draws do not progress paused cross-fades")
		case 10: worker_pause(&world,actors,false);dt=0.4
		case 11: force_revision(manager,Worker_Punch)
		case 12:
			renderer,_:=ecs.get_model_renderer(&world,actors[0]);renderer.model=Model;renderer.material=""
			assert(ecs.set_model_renderer(&world,actors[0],renderer));assert(ecs.play_model_animation(&world,actors[0],"bend"))
			animator,_:=ecs.get_model_animator(&world,actors[0]);animator.events=""
			assert(ecs.set_model_animator(&world,actors[0],animator))
			assert(ecs.set_enabled(&world,actors[2],false));dt=0.1
		case 13:
			assert(ecs.remove_component(&world,actors[3],"ModelAnimator"));assert(ecs.destroy_entity(&world,actors[4]));dt=0.1
		case 14: force_revision(manager,Strut)
		case 15: assert(ecs.remove_component(&world,actors[0],"ModelRenderer"))
		case 16:
			previous_generation:=world.generation
			ecs.destroy(&world);world,actors=worker_world(registry)
			assert(world.generation!=previous_generation);dt=0.1
		case 17:
		case 18,19:
			if parallel {worker_busy_update(ctx,&world,manager,checkpoint==18)} else {bridge.update_animations(ctx,&world,manager,0.05)}
		}
		if checkpoint!=3 && checkpoint!=9 && checkpoint<18 {bridge.update_animations(ctx,&world,manager,dt)}
		if checkpoint==0 {assert(ctx.animation_stats.players_evaluated==Worker_Actors && ctx.animation_stats.bones_evaluated==Worker_Actors*52)}
		if checkpoint==5 {
			forward,reverse:=state(&world,actors[0]),state(&world,actors[1])
			assert(forward.finished && reverse.finished && !forward.playing && !reverse.playing && near(forward.elapsed,forward.duration) && reverse.elapsed==0,"both nonloop endpoints finish exactly")
			reverse_event:=false
			for event in ecs.model_animation_events(&world) {if event.entity==actors[1] && event.reverse {reverse_event=true}}
			assert(reverse_event,"the parity fixture includes reverse marker crossings")
		}
		if checkpoint==8 {assert(near(ctx.animation_players[actors[5]].blend_elapsed,0.15),"pause freezes the blend clock")}
		if checkpoint==10 {for entity in actors {assert(len(ctx.animation_players[entity].blend_pose)==0,"finished blends release their snapshots after the worker barrier")}}
		if checkpoint==13 {_,found:=ctx.animation_players[actors[3]];assert(!found);_,found=ctx.animation_players[actors[4]];assert(!found)}
		if checkpoint==15 {_,found:=ctx.animation_players[actors[0]];assert(!found)}
		if checkpoint==16 {assert(len(ctx.animation_players)==Worker_Actors && ctx.animation_world_generation==world.generation)}
		if checkpoint==17 {assert(ctx.animation_stats.players_evaluated==0 && ctx.animation_stats.job_batches==0,"zero-delta unchanged update avoids pose work")}
		actual:=worker_snapshot(ctx,&world,actors)
		if checkpoint==0 {for item in actual.actors {assert(item.event_count==0,"zero delta does not start marker emission")}}
		if checkpoint==1 {
			assert(actual.actors[10].event_count==2,"the marker fixture emits the initial and crossed markers")
			assert(actual.actors[10].local!=expected[0].actors[10].local && actual.actors[10].uploaded!=expected[0].actors[10].uploaded,"timeline advancement changes both CPU pose and GPU skin pixels")
		}
		if parallel {
			assert(actual.players==expected[checkpoint].players && actual.bones==expected[checkpoint].bones)
			for item,index in actual.actors {assert(item==expected[checkpoint].actors[index],fmt.tprintf("serial/worker pose, uploaded pixels, timeline and per-actor events differ at checkpoint %d actor %d",checkpoint,index))}
			if actual.bones>=bridge.Animation_Parallel_Min_Bones && actual.players>=2 {assert(ctx.animation_stats.job_batches==1,"the actual bridge selected the jobs batch")}
		} else {expected[checkpoint]=actual;assert(ctx.animation_stats.job_batches==0)}
	}
	ctx.worker_pool=nil
}

validate_animation_workers_runtime :: proc(registry:^ecs.Component_Registry) {
	rl.SetTraceLogLevel(.WARNING);rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,240,"Rune animation worker validation");defer rl.CloseWindow()
	assert(rl.IsWindowReady())
	gl.load_up_to(3,3,proc(pointer:rawptr,name:cstring) {(^rawptr)(pointer)^=rlgl.GetProcAddress(name)})
	output::"build/model-animation-worker-markers.model-events.json"
	assert(os.write_entire_file(output,`{"clips":{"mixamo.com":[{"time":0,"name":"start"},{"time":0.2,"name":"step"},{"time":0.6,"name":"land"}],"worker_punch":[{"time":0.1,"name":"impact"},{"time":0.6,"name":"recover"}]}}`)==nil)
	defer os.remove(output)
	pool:=jobs.create(3,1);assert(pool!=nil);defer jobs.destroy(pool)
	manager:=assets.init(Root);defer assets.shutdown(&manager)
	ctx,ok:=bridge.init(Root,320,240);assert(ok);defer bridge.shutdown(&ctx)
	assert(bridge.register_model_animation_source(&ctx,Strut,"worker_punch",Worker_Punch))
	r3d.SetOutputMode(.ALBEDO);defer r3d.SetOutputMode(.SCENE)
	expected:[Worker_Checkpoints]Worker_Snapshot
	worker_pass(&ctx,&manager,registry,nil,&expected,false)
	worker_pass(&ctx,&manager,registry,pool,&expected,true)
	fmt.printf("Animation worker runtime passed: %d actors, %d bones, %d serial/worker checkpoints; native skin uploads, ordinary draws, reloads, full/free queue barriers\n",Worker_Actors,Worker_Actors*52,Worker_Checkpoints)
}
