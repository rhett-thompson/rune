package core

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "rune:console"
import "rune:ecs"

Console_Batch_Test :: struct {
	engine: Engine,
	world: ecs.World,
	entity: ecs.Entity,
	arena: mem.Dynamic_Arena,
	directory, batch_path, command_path, reply_path: string,
}

console_batch_test_init :: proc(f: ^Console_Batch_Test) {
	mem.dynamic_arena_init(&f.arena)
	directory, err := os.make_directory_temp("build", "console-core-batch-*", context.allocator)
	assert(err == nil)
	f.directory = directory
	f.batch_path = fmt.aprintf("%s/request.batch", directory)
	f.command_path = fmt.aprintf("%s/request.cmd", directory)
	f.reply_path = fmt.aprintf("%s/request.result.json", directory)
	f.world = ecs.init()
	f.engine.registry = ecs.init_registry()
	assert(ecs.register_builtin_components(&f.engine.registry))
	f.entity = ecs.create_entity(&f.world)
	assert(ecs.set_entity_metadata(&f.world, f.entity, "player", "Player", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&f.world, &f.engine.registry, f.entity, "Transform", json.Object{}))
	f.engine.console = console.init()
	f.engine.fixed_delta_time = 1.0 / 60.0
	f.engine.debug.paused = true
	register_debug_commands(&f.engine.console)
	bind_debug_console(&f.engine, &f.world)
	assert(console.enable_remote(&f.engine.console, directory))
}

console_batch_test_destroy :: proc(f: ^Console_Batch_Test) {
	console.stop_remote(&f.engine.console)
	for path in ([3]string{f.batch_path, f.command_path, f.reply_path}) {
		os.remove(path)
		delete(path)
	}
	os.remove(f.directory)
	delete(f.directory)
	ecs.destroy(&f.world)
	ecs.destroy_registry(&f.engine.registry)
	mem.dynamic_arena_destroy(&f.arena)
}

// Model the loop's frame boundary and a deterministic game update. The real
// step command chooses/finishes simulation ticks; polling still sees idle frames.
console_batch_test_frame :: proc(f: ^Console_Batch_Test) {
	f.engine.console.result_data = {}
	f.engine.console.frame_metadata = {}
	mem.dynamic_arena_reset(&f.arena)
	f.engine.debug.frame += 1
	console.poll_remote(&f.engine.console, f64(f.engine.debug.frame) / 60)
	finish_exit_console(&f.engine)
	if f.engine.exit_requested {return}
	if debug_simulation_tick(&f.engine) {
		pose, found := ecs.get_transform(&f.world, f.entity)
		assert(found)
		pose.position[0] += 1
		assert(ecs.set_transform(&f.world, f.entity, pose))
		f.engine.debug.fixed_steps += 1
		debug_simulation_finished(&f.engine)
	}
	f.engine.console.frame_metadata = debug_frame_metadata(&f.engine)
	console.finish_remote(&f.engine.console)
}

console_batch_test_reply :: proc(f: ^Console_Batch_Test) -> json.Value {
	for _ in 0..<1000 {
		if os.exists(f.reply_path) {break}
		console_batch_test_frame(f)
	}
	data, err := os.read_entire_file(f.reply_path, context.allocator)
	assert(err == nil, "batch reply must arrive after the required frames")
	defer delete(data)
	value: json.Value
	assert(json.unmarshal(data, &value) == nil)
	assert(os.remove(f.reply_path) == nil)
	return value
}

console_batch_test_x :: proc(data: json.Value) -> f64 {
	x, ok := ecs.read_number(data.(json.Object)["components"].(json.Object)["Transform"].(json.Object)["position"].(json.Array)[0])
	assert(ok)
	return f64(x)
}

@(test)
console_batch_matches_serial_set_step_and_inspect_across_frame_resets :: proc(t: ^testing.T) {
	batch, serial: Console_Batch_Test
	console_batch_test_init(&batch)
	defer console_batch_test_destroy(&batch)
	console_batch_test_init(&serial)
	defer console_batch_test_destroy(&serial)
	commands := [3]string{"set player Transform.position.0 5", "step 60", "inspect player Transform"}
	context.temp_allocator = mem.dynamic_arena_allocator(&batch.arena)
	assert(os.write_entire_file(batch.batch_path, strings.join(commands[:], "\n", context.temp_allocator)) == nil)
	batch_reply := console_batch_test_reply(&batch)
	defer json.destroy_value(batch_reply)
	object := batch_reply.(json.Object)
	testing.expect(t, object["ok"].(json.Boolean) && object["complete"].(json.Boolean))
	testing.expect(t, object["requested"].(json.Integer) == 3 && object["completed"].(json.Integer) == 3)
	entries := object["results"].(json.Array)
	if !testing.expect(t, len(entries) == 3) {return}
	testing.expect(t, batch.engine.debug.frame == 62, "the next command starts on the frame after step completion")
	testing.expect(t, console_batch_test_x(entries[0].(json.Object)["data"]) == 5)
	testing.expect(t, console_batch_test_x(entries[2].(json.Object)["data"]) == 65)
	for command, index in commands {
		context.temp_allocator = mem.dynamic_arena_allocator(&serial.arena)
		assert(os.write_entire_file(serial.command_path, command) == nil)
		reply := console_batch_test_reply(&serial)
		defer json.destroy_value(reply)
		single := reply.(json.Object)
		entry := entries[index].(json.Object)
		testing.expect(t, single["ok"].(json.Boolean) && entry["ok"].(json.Boolean))
		single_lines, batch_lines := single["lines"].(json.Array), entry["lines"].(json.Array)
		if testing.expect(t, len(single_lines) == len(batch_lines)) {
			for line, line_index in single_lines {testing.expect(t, line.(json.String) == batch_lines[line_index].(json.String))}
		}
		if index != 1 {
			testing.expect(t, console_batch_test_x(single["data"]) == console_batch_test_x(entry["data"]))
		} else {
			// Status includes frame/FPS, which intentionally need not be identical.
			for data in ([2]json.Value{single["data"], entry["data"]}) {
				status := data.(json.Object)
				testing.expect(t, status["paused"].(json.Boolean) && status["simulation_updates"].(json.Integer) == 60)
				metadata := status["metadata"].(json.Object)
				time_value, ok := ecs.read_number(metadata["simulation_time"])
				testing.expect(t, ok && math.abs(time_value - 1) < 0.000001)
				testing.expect(t, metadata["simulation_steps"].(json.Integer) == 60)
			}
		}
	}
	batch_pose, _ := ecs.get_transform(&batch.world, batch.entity)
	serial_pose, _ := ecs.get_transform(&serial.world, serial.entity)
	testing.expect(t, batch_pose == serial_pose && serial.engine.debug.frame > batch.engine.debug.frame)
}

@(test)
console_batch_quit_reports_the_completed_prefix_before_early_loop_exit :: proc(t: ^testing.T) {
	f: Console_Batch_Test
	console_batch_test_init(&f)
	defer console_batch_test_destroy(&f)
	context.temp_allocator = mem.dynamic_arena_allocator(&f.arena)
	assert(os.write_entire_file(f.batch_path, "status\nquit\nset player Transform.position.0 99") == nil)
	reply := console_batch_test_reply(&f)
	defer json.destroy_value(reply)
	object := reply.(json.Object)
	testing.expect(t, !object["ok"].(json.Boolean) && !object["complete"].(json.Boolean))
	testing.expect(t, object["requested"].(json.Integer) == 3 && object["completed"].(json.Integer) == 2)
	entries := object["results"].(json.Array)
	if testing.expect(t, len(entries) == 2) {
		quit := entries[1].(json.Object)
		testing.expect(t, quit["ok"].(json.Boolean) && quit["data"].(json.Object)["exit_requested"].(json.Boolean))
	}
	pose, _ := ecs.get_transform(&f.world, f.entity)
	testing.expect(t, f.engine.exit_requested && pose.position[0] == 0 && f.engine.console.remote.result_len == 0)
}

@(test)
console_batch_stop_finalizes_between_entries_and_during_a_step :: proc(t: ^testing.T) {
	for deferred in ([2]bool{false, true}) {
		f: Console_Batch_Test
		console_batch_test_init(&f)
		defer console_batch_test_destroy(&f)
		context.temp_allocator = mem.dynamic_arena_allocator(&f.arena)
		assert(os.write_entire_file(f.batch_path, "step 600\nstatus" if deferred else "status\nstatus") == nil)
		console_batch_test_frame(&f)
		testing.expect(t, !os.exists(f.reply_path) && f.engine.console.defer_reply == deferred)
		console.stop_remote(&f.engine.console)
		reply := console_batch_test_reply(&f)
		defer json.destroy_value(reply)
		object := reply.(json.Object)
		testing.expect(t, !object["ok"].(json.Boolean) && !object["complete"].(json.Boolean))
		testing.expect(t, object["requested"].(json.Integer) == 2 && object["completed"].(json.Integer) == 1)
		entries := object["results"].(json.Array)
		if testing.expect(t, len(entries) == 1) {testing.expect(t, entries[0].(json.Object)["ok"].(json.Boolean) == !deferred)}
		testing.expect(t, !f.engine.console.defer_reply && f.engine.console.remote.result_len == 0)
	}
}
