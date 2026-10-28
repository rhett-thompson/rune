package core

import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"
import "rune:console"
import "rune:ecs"

// Model both loop boundaries: commands/ticks precede drawing, while profile
// completion follows presentation. Native rendering is unnecessary for these
// command-state and transport checks.
@(private="file")
profile_step_test_frame :: proc(f:^Console_Batch_Test,finish_profile:bool=true) {
	f.engine.console.result_data={}
	f.engine.console.frame_metadata={}
	mem.dynamic_arena_reset(&f.arena)
	f.engine.debug.frame+=1
	f.engine.debug.frame_started=f64(f.engine.debug.frame)*0.01
	f.engine.debug.sample={update_ms=f64(f.engine.debug.frame),fixed_update_ms=2*f64(f.engine.debug.frame),render_ms=3*f64(f.engine.debug.frame)}
	console.poll_remote(&f.engine.console,f64(f.engine.debug.frame)/60)
	if debug_simulation_tick(&f.engine) {
		pose,found:=ecs.get_transform(&f.world,f.entity);assert(found)
		pose.position[0]+=1
		assert(ecs.set_transform(&f.world,f.entity,pose))
		f.engine.debug.fixed_steps+=1
		debug_simulation_finished(&f.engine)
	}
	f.engine.console.frame_metadata=debug_frame_metadata(&f.engine)
	console.finish_remote(&f.engine.console)
	if finish_profile {debug_profile_finished_frame(&f.engine,f.engine.debug.frame_started+0.004)}
}

@(test)
profile_step_parser_requires_pause_and_rejects_invalid_counts_atomically :: proc(t:^testing.T) {
	arena:mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator=mem.dynamic_arena_allocator(&arena)
	for command,index in ([4]string{"profile --step","profile --step 1","profile --step 600","profile 7"}) {
		engine:Engine
		engine.console=console.init();engine.debug.paused=true;engine.window.target_fps=144
		register_debug_commands(&engine.console);bind_debug_console(&engine,nil)
		assert(console.execute(&engine.console,command))
		counts:=[4]int{120,1,600,7}
		count:=counts[index]
		testing.expect(t,engine.console.error_count==0 && engine.console.defer_reply)
		testing.expect(t,engine.debug.profile_target==count && engine.debug.profile_count==0)
		testing.expect(t,engine.debug.profile_stepping==(index<3))
		testing.expect(t,engine.debug.steps_remaining==(count if index<3 else 0) && debug_simulation_budget(&engine)==1)
		testing.expect(t,engine.debug.paused && !engine.debug.fast_step && !engine.window.step_uncapped && engine.window.target_fps==144)
		stop_debug_console(&engine)
	}
	for command in ([7]string{"profile --step 0","profile --step 601","profile --step -1","profile --step 1 extra","profile --step nope","profile --fast 1","profile --step 1.5"}) {
		engine:Engine
		engine.console=console.init();engine.debug.paused=true
		register_debug_commands(&engine.console);bind_debug_console(&engine,nil)
		assert(console.execute(&engine.console,command))
		testing.expect(t,engine.console.error_count==1 && !engine.console.defer_reply,command)
		testing.expect(t,engine.debug.profile_target==0 && !engine.debug.profile_stepping && engine.debug.steps_remaining==0,command)
	}
	engine:Engine
	engine.console=console.init()
	register_debug_commands(&engine.console);bind_debug_console(&engine,nil)
	assert(console.execute(&engine.console,"profile --step 1"))
	testing.expect(t,engine.console.error_count==1 && !engine.console.defer_reply && engine.debug.profile_target==0 && engine.debug.steps_remaining==0)
}

@(test)
profile_step_remote_reply_waits_for_the_final_presented_frame :: proc(t:^testing.T) {
	f:Console_Batch_Test
	console_batch_test_init(&f);defer console_batch_test_destroy(&f)
	context.temp_allocator=mem.dynamic_arena_allocator(&f.arena)
	assert(os.write_entire_file(f.command_path,"profile --step 3")==nil)
	for _ in 0..<2 {
		profile_step_test_frame(&f)
		testing.expect(t,!os.exists(f.reply_path) && f.engine.console.defer_reply && f.engine.debug.profile_stepping)
	}
	profile_step_test_frame(&f,finish_profile=false)
	testing.expect(t,f.engine.debug.steps_remaining==0 && f.engine.debug.profile_count==2 && f.engine.console.defer_reply,
		"the final tick cannot publish a step status before the profile's final frame is presented")
	testing.expect(t,!os.exists(f.reply_path))
	debug_profile_finished_frame(&f.engine,f.engine.debug.frame_started+0.004)
	if !testing.expect(t,os.exists(f.reply_path)) {return}
	reply:=console_batch_test_reply(&f);defer json.destroy_value(reply)
	object:=reply.(json.Object);data:=object["data"].(json.Object)
	testing.expect(t,object["ok"].(json.Boolean) && data["frames"].(json.Integer)==3 && data["stepped_frames"].(json.Integer)==3)
	mean,valid:=ecs.read_number(data["fixed_update"].(json.Object)["mean_ms"])
	testing.expect(t,valid && math.abs(f64(mean)-4)<0.000001,"the profile includes all three controlled fixed-update frames")
	mean,valid=ecs.read_number(data["frame"].(json.Object)["mean_ms"])
	testing.expect(t,valid && math.abs(f64(mean)-4)<0.000001,"frame duration includes the supplied presentation boundary")
	pose,_:=ecs.get_transform(&f.world,f.entity)
	testing.expect(t,pose.position[0]==3 && f.engine.debug.fixed_steps==3 && f.engine.debug.simulation_updates==3)
	testing.expect(t,f.engine.debug.paused && !f.engine.console.defer_reply && !f.engine.debug.profile_stepping && f.engine.debug.profile_target==0)
	profile_step_test_frame(&f)
	testing.expect(t,!os.exists(f.reply_path) && f.engine.debug.simulation_updates==3,"completion cannot emit a second reply or advance another paused tick")
}

@(test)
profile_step_batch_preserves_one_tick_per_frame_and_ordinary_profiling :: proc(t:^testing.T) {
	f:Console_Batch_Test
	console_batch_test_init(&f);defer console_batch_test_destroy(&f)
	context.temp_allocator=mem.dynamic_arena_allocator(&f.arena)
	assert(os.write_entire_file(f.batch_path,"profile --step 3\ninspect player Transform\nprofile 2")==nil)
	for _ in 0..<6 {profile_step_test_frame(&f)}
	if !testing.expect(t,os.exists(f.reply_path)) {return}
	reply:=console_batch_test_reply(&f);defer json.destroy_value(reply)
	object:=reply.(json.Object)
	testing.expect(t,object["ok"].(json.Boolean) && object["complete"].(json.Boolean) && object["completed"].(json.Integer)==3)
	entries:=object["results"].(json.Array)
	if !testing.expect(t,len(entries)==3) {return}
	first:=entries[0].(json.Object)["data"].(json.Object)
	last:=entries[2].(json.Object)["data"].(json.Object)
	testing.expect(t,first["frames"].(json.Integer)==3 && first["stepped_frames"].(json.Integer)==3)
	testing.expect(t,console_batch_test_x(entries[1].(json.Object)["data"])==3,"the next batch command sees all profiled ticks")
	testing.expect(t,last["frames"].(json.Integer)==2 && last["stepped_frames"].(json.Integer)==0,"ordinary paused profiling does not advance simulation")
	testing.expect(t,f.engine.debug.frame==6 && f.engine.debug.simulation_updates==3 && f.engine.debug.paused)
}

@(test)
profile_step_stop_cancels_pending_measurement_without_a_late_reply :: proc(t:^testing.T) {
	f:Console_Batch_Test
	console_batch_test_init(&f);defer console_batch_test_destroy(&f)
	context.temp_allocator=mem.dynamic_arena_allocator(&f.arena)
	assert(os.write_entire_file(f.batch_path,"profile --step 600\nstatus")==nil)
	profile_step_test_frame(&f)
	testing.expect(t,f.engine.debug.steps_remaining==599 && f.engine.debug.profile_count==1 && f.engine.console.defer_reply)
	stop_debug_console(&f.engine)
	testing.expect(t,f.engine.debug.steps_remaining==0 && f.engine.debug.profile_target==0 && !f.engine.debug.profile_stepping && !f.engine.console.defer_reply)
	if !testing.expect(t,os.exists(f.reply_path)) {return}
	reply:=console_batch_test_reply(&f);defer json.destroy_value(reply)
	object:=reply.(json.Object)
	testing.expect(t,!object["ok"].(json.Boolean) && !object["complete"].(json.Boolean) && object["completed"].(json.Integer)==1)
	profile_step_test_frame(&f)
	testing.expect(t,!os.exists(f.reply_path) && f.engine.debug.simulation_updates==1,"canceled profiling stays canceled on later frames")
}
