package core

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"
import "rune:console"
import "rune:ecs"
import "rune:input"

// Use real fixed/update dispatch so equivalent step counts must produce the
// same state, including the ordering of those phases within every tick.
@(private="file")
fast_step_test_fixed :: proc(engine: ^Engine, world: ^ecs.World) {
	for entity in world.entities {
		pose, found := ecs.get_transform(world, entity)
		if !found {continue}
		pose.position[0] += 1
		assert(ecs.set_transform(world, entity, pose))
	}
}

@(private="file")
fast_step_test_update :: proc(engine: ^Engine, world: ^ecs.World) {
	for entity in world.entities {
		pose, found := ecs.get_transform(world, entity)
		if !found {continue}
		pose.position[1] = pose.position[0]
		assert(ecs.set_transform(world, entity, pose))
	}
}

// Model frame boundaries without a native window; native pacing is separately
// exercised by the runtime validator. Result memory is reset every frame.
@(private="file")
fast_step_test_frame :: proc(f: ^Console_Batch_Test) {
	f.engine.console.result_data = {}
	f.engine.console.frame_metadata = {}
	mem.dynamic_arena_reset(&f.arena)
	f.engine.debug.frame += 1
	console.poll_remote(&f.engine.console, f64(f.engine.debug.frame) / 60)
	finish_exit_console(&f.engine)
	if f.engine.exit_requested {return}
	simulation_budget := debug_simulation_budget(&f.engine)
	for tick_index in 0..<simulation_budget {
		debug_prepare_simulation_tick(&f.engine, tick_index)
		if !debug_simulation_tick(&f.engine) {break}
		run_fixed_pipeline(&f.engine, &f.world)
		run_update_systems(&f.engine, &f.world)
		debug_simulation_finished(&f.engine)
	}
	f.engine.console.frame_metadata = debug_frame_metadata(&f.engine)
	console.finish_remote(&f.engine.console)
}

@(test)
fast_step_parser_accepts_defaults_and_rejects_invalid_arguments_atomically :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	for command, index in ([6]string{"step", "step --fast", "step 1", "step --fast 1", "step 600", "step --fast 600"}) {
		engine: Engine
		engine.console = console.init()
		engine.debug.paused = true
		engine.window.target_fps = 144
		engine.project.window.target_fps = 60
		register_debug_commands(&engine.console)
		bind_debug_console(&engine, nil)
		assert(console.execute(&engine.console, command))
		fast := index % 2 == 1
		count := 600 if index >= 4 else 1
		testing.expect(t, engine.console.error_count == 0 && engine.console.defer_reply)
		testing.expect(t, engine.debug.steps_requested == count && engine.debug.steps_remaining == count)
		testing.expect(t, engine.debug.fast_step == fast && engine.window.step_uncapped == fast)
		testing.expect(t, engine.window.target_fps == 144 && engine.project.window.target_fps == 60)
		stop_debug_console(&engine)
	}
	for command in ([11]string{"step --fast 0", "step --fast 601", "step --fast -1", "step --fast --fast", "step --fast 9 --fast", "step 9 --fast", "step --fast 1 extra", "step --fast nope", "step --fast 1.5", "step --unknown", "step --fast 9999999999999999999999999"}) {
		engine: Engine
		engine.console = console.init()
		engine.debug.paused = true
		engine.window.target_fps = 144
		register_debug_commands(&engine.console)
		bind_debug_console(&engine, nil)
		assert(console.execute(&engine.console, command))
		testing.expect(t, engine.console.error_count == 1 && !engine.console.defer_reply, command)
		testing.expect(t, engine.debug.steps_remaining == 0 && engine.debug.steps_requested == 0, command)
		testing.expect(t, !engine.debug.fast_step && !engine.window.step_uncapped && engine.window.target_fps == 144, command)
	}
	engine: Engine
	engine.console = console.init()
	register_debug_commands(&engine.console)
	bind_debug_console(&engine, nil)
	assert(console.execute(&engine.console, "step --fast 1"))
	testing.expect(t, engine.console.error_count == 1 && !engine.console.defer_reply)
	testing.expect(t, !engine.debug.fast_step && !engine.window.step_uncapped && engine.debug.steps_remaining == 0)
}

@(test)
fast_step_completion_suggests_the_flag_only_before_the_count :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	engine: Engine
	engine.console = console.init()
	register_debug_commands(&engine.console)
	bind_debug_console(&engine, nil)
	for text, index in ([5]string{"step ", "step --f", "step --fast ", "step 9 ", "step 9 --f"}) {
		console.edit(&engine.console, .Select_All)
		assert(console.insert_text(&engine.console, text))
		matches := console.completion_matches(&engine.console)
		if index < 2 {
			if testing.expect(t, len(matches.options) == 1) {testing.expect(t, matches.options[0].value == "--fast")}
		} else {testing.expect(t, len(matches.options) == 0)}
	}
}

@(test)
fast_step_matches_plain_simulation_for_boundary_counts :: proc(t: ^testing.T) {
	for count in ([5]int{1, 7, 8, 9, 600}) {
		for fast in ([2]bool{false, true}) {
			f: Console_Batch_Test
			console_batch_test_init(&f)
			defer console_batch_test_destroy(&f)
			context.temp_allocator = mem.dynamic_arena_allocator(&f.arena)
			f.engine.window.target_fps = 144
			f.engine.project.window.target_fps = 60
			assert(register_system(&f.engine, {name = "step-order", fixed_update = fast_step_test_fixed, update = fast_step_test_update}))
			defer delete(f.engine.systems)
			assert(console.execute(&f.engine.console, fmt.tprintf("step %s%d", "--fast " if fast else "", count)))
			for f.engine.debug.steps_remaining > 0 {
				expected_budget := min(8, f.engine.debug.steps_remaining) if fast else 1
				testing.expect(t, debug_simulation_budget(&f.engine) == expected_budget)
				fast_step_test_frame(&f)
			}
			pose, found := ecs.get_transform(&f.world, f.entity)
			testing.expect(t, found && pose.position[0] == f32(count) && pose.position[1] == f32(count))
			testing.expect(t, f.engine.debug.frame == u64((count + 7) / 8 if fast else count))
			testing.expect(t, f.engine.debug.fixed_steps == u64(count) && f.engine.debug.simulation_updates == u64(count))
			testing.expect(t, math.abs(f.engine.debug.simulation_time - f64(count) / 60) < 0.000001)
			testing.expect(t, f.engine.debug.paused && !f.engine.debug.fast_step && !f.engine.window.step_uncapped)
			testing.expect(t, f.engine.window.target_fps == 144 && f.engine.project.window.target_fps == 60)
			testing.expect(t, !f.engine.console.defer_reply && !debug_simulation_tick(&f.engine))
			// finish_remote consumes a local command's result at the frame end.
			// Re-read status to compare only deterministic simulation fields.
			debug_status(&f.engine)
			status := f.engine.console.result_data.(json.Object)
			testing.expect(t, status["paused"].(json.Boolean) && status["simulation_updates"].(json.Integer) == json.Integer(count))
			testing.expect(t, status["metadata"].(json.Object)["simulation_steps"].(json.Integer) == json.Integer(count))
		}
	}
}

@(test)
fast_step_consumes_physical_transients_once_and_advances_injected_edges :: proc(t: ^testing.T) {
	f: Console_Batch_Test
	console_batch_test_init(&f)
	defer console_batch_test_destroy(&f)
	context.temp_allocator = mem.dynamic_arena_allocator(&f.arena)
	controls, loaded := input.load("examples/tilemap_2d/input/default.input.json")
	if !testing.expect(t, loaded) {return}
	f.engine.input = controls
	defer input.destroy(&f.engine.input)
	assert(input.inject_action(&f.engine.input, "move_right", true))
	f.engine.input.actions["physical"] = {is_down = true, pressed = true, strength = 1}
	f.engine.input.mappings.axes["mouse"] = {type = "mouse_delta", axis = "x"}
	f.engine.input.mappings.axes["stick"] = {type = "gamepad_axis", axis = "LEFT_X"}
	f.engine.input.axes["mouse"] = 7
	f.engine.input.axes["stick"] = 0.5
	assert(console.execute(&f.engine.console, "step --fast 9"))
	pressed, released, physical_pressed, physical_down, ticks, frames: int
	mouse_total, stick_total: f32
	for f.engine.debug.steps_remaining > 0 {
		frames += 1
		// Model the next rendered frame's fresh sample with the button held and
		// no additional mouse displacement. Earlier ticks share the first sample.
		if frames > 1 {input.clear_transients(&f.engine.input)}
		simulation_budget := debug_simulation_budget(&f.engine)
		for tick_index in 0..<simulation_budget {
			if ticks == 5 {assert(input.inject_action(&f.engine.input, "move_right", false))}
			debug_prepare_simulation_tick(&f.engine, tick_index)
			assert(debug_simulation_tick(&f.engine))
			state := f.engine.input.actions["move_right"]
			if state.pressed {pressed += 1}
			if state.released {released += 1}
			if f.engine.input.actions["physical"].pressed {physical_pressed += 1}
			if f.engine.input.actions["physical"].is_down {physical_down += 1}
			mouse_total += f.engine.input.axes["mouse"]
			stick_total += f.engine.input.axes["stick"]
			debug_simulation_finished(&f.engine)
			ticks += 1
		}
	}
	testing.expect(t, ticks == 9 && frames == 2 && pressed == 1 && released == 1)
	testing.expect(t, physical_pressed == 1 && physical_down == 9)
	testing.expect(t, mouse_total == 7 && stick_total == 4.5)
}

@(test)
fast_step_batch_defers_following_entries_and_continues_after_failure :: proc(t: ^testing.T) {
	f: Console_Batch_Test
	console_batch_test_init(&f)
	defer console_batch_test_destroy(&f)
	context.temp_allocator = mem.dynamic_arena_allocator(&f.arena)
	f.engine.window.target_fps = 144
	assert(os.write_entire_file(f.batch_path, "step --fast 9\nmissing_fast_step_command\nstatus") == nil)
	fast_step_test_frame(&f)
	testing.expect(t, f.engine.debug.steps_remaining == 1 && f.engine.debug.simulation_updates == 8)
	testing.expect(t, f.engine.console.defer_reply && f.engine.window.step_uncapped && !os.exists(f.reply_path))
	fast_step_test_frame(&f)
	testing.expect(t, f.engine.debug.simulation_updates == 9 && !f.engine.console.defer_reply)
	testing.expect(t, !f.engine.window.step_uncapped && f.engine.window.target_fps == 144 && !os.exists(f.reply_path))
	fast_step_test_frame(&f)
	testing.expect(t, f.engine.console.error_count == 1 && !os.exists(f.reply_path))
	fast_step_test_frame(&f)
	if !testing.expect(t, os.exists(f.reply_path)) {return}
	reply := console_batch_test_reply(&f)
	defer json.destroy_value(reply)
	object := reply.(json.Object)
	testing.expect(t, object["complete"].(json.Boolean) && !object["ok"].(json.Boolean))
	testing.expect(t, object["requested"].(json.Integer) == 3 && object["completed"].(json.Integer) == 3)
	entries := object["results"].(json.Array)
	if !testing.expect(t, len(entries) == 3) {return}
	testing.expect(t, entries[0].(json.Object)["ok"].(json.Boolean) && !entries[1].(json.Object)["ok"].(json.Boolean) && entries[2].(json.Object)["ok"].(json.Boolean))
	for index in ([2]int{0, 2}) {
		status := entries[index].(json.Object)["data"].(json.Object)
		testing.expect(t, status["simulation_updates"].(json.Integer) == 9)
		metadata := status["metadata"].(json.Object)
		testing.expect(t, metadata["frame"].(json.Integer) == json.Integer(2 if index == 0 else 4))
	}
}

@(test)
fast_step_stop_restores_pacing_and_reports_interrupted_final_or_prefix :: proc(t: ^testing.T) {
	for has_suffix in ([2]bool{false, true}) {
		f: Console_Batch_Test
		console_batch_test_init(&f)
		defer console_batch_test_destroy(&f)
		context.temp_allocator = mem.dynamic_arena_allocator(&f.arena)
		f.engine.window.target_fps = 144
		f.engine.project.window.target_fps = 60
		assert(os.write_entire_file(f.batch_path, "step --fast 600\nstatus" if has_suffix else "step --fast 600") == nil)
		fast_step_test_frame(&f)
		testing.expect(t, f.engine.debug.steps_remaining == 592 && f.engine.console.defer_reply && f.engine.window.step_uncapped)
		stop_debug_console(&f.engine)
		testing.expect(t, f.engine.debug.steps_remaining == 0 && !f.engine.debug.fast_step && !f.engine.window.step_uncapped)
		testing.expect(t, !f.engine.console.defer_reply && f.engine.window.target_fps == 144 && f.engine.project.window.target_fps == 60)
		if !testing.expect(t, os.exists(f.reply_path)) {continue}
		reply := console_batch_test_reply(&f)
		defer json.destroy_value(reply)
		object := reply.(json.Object)
		testing.expect(t, !object["ok"].(json.Boolean) && object["complete"].(json.Boolean) == !has_suffix)
		testing.expect(t, object["requested"].(json.Integer) == json.Integer(2 if has_suffix else 1) && object["completed"].(json.Integer) == 1)
		entries := object["results"].(json.Array)
		if testing.expect(t, len(entries) == 1) {
			entry := entries[0].(json.Object)
			_, null := entry["data"].(json.Null)
			testing.expect(t, !entry["ok"].(json.Boolean) && null)
		}
		stop_debug_console(&f.engine)
		testing.expect(t, !os.exists(f.reply_path) && f.engine.console.remote.result_len == 0)
	}
}
