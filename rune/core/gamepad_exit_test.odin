package core

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"
import "rune:console"

@(test)
gamepad_exit_requires_continuous_hold_and_fires_once :: proc(t: ^testing.T) {
	state: Gamepad_Exit_State
	held := [4]bool{true, false, false, false}
	testing.expect(t, !gamepad_exit_tick(&state, held, 0.4, true, true))
	testing.expect(t, !gamepad_exit_tick(&state, held, 0.4, true, true))
	testing.expect(t, gamepad_exit_tick(&state, held, 0.21, true, true))
	testing.expect(t, !gamepad_exit_tick(&state, held, 10, true, true), "a finished hold never retriggers")
	testing.expect(t, !gamepad_exit_tick(&state, {}, 0.1, true, true))
	testing.expect(t, state.elapsed[0] == 0 && !state.fired[0])
	testing.expect(t, !gamepad_exit_tick(&state, held, 0.2, true, true), "a tap stays below the exit threshold")
	testing.expect(t, !gamepad_exit_tick(&state, {}, 0.1, true, true))
	testing.expect(t, !gamepad_exit_tick(&state, held, 0.81, true, true), "released taps do not accumulate")
	testing.expect(t, gamepad_exit_tick(&state, held, 0.2, true, true))
}

@(test)
gamepad_exit_ignores_invalid_time_and_controller_handoff :: proc(t: ^testing.T) {
	state: Gamepad_Exit_State
	first := [4]bool{true, false, false, false}
	second := [4]bool{false, true, false, false}
	testing.expect(t, !gamepad_exit_tick(&state, first, 0.7, true, true))
	for dt in ([4]f32{0, -1, math.nan_f32(), math.inf_f32(1)}) {
		testing.expect(t, !gamepad_exit_tick(&state, first, dt, true, true))
	}
	testing.expect(t, state.elapsed[0] == 0.7)
	testing.expect(t, !gamepad_exit_tick(&state, second, 0.4, true, true), "another pad starts its own hold")
	testing.expect(t, state.elapsed[0] == 0)
	testing.expect(t, !gamepad_exit_tick(&state, second, 0.5, true, true))
	testing.expect(t, gamepad_exit_tick(&state, second, 0.11, true, true))
	testing.expect(t, !gamepad_exit_tick(&state, {}, math.nan_f32(), true, true), "disconnect clears holds even when dt is invalid")
	testing.expect(t, state == Gamepad_Exit_State{})
	testing.expect(t, !gamepad_exit_tick(nil, first, 1, true, true))
}

@(test)
gamepad_exit_focus_opt_out_and_round_reset :: proc(t: ^testing.T) {
	state: Gamepad_Exit_State
	held := [4]bool{false, false, false, true}
	testing.expect(t, !gamepad_exit_tick(&state, held, 0.8, true, true))
	testing.expect(t, !gamepad_exit_tick(&state, held, 1, false, true))
	testing.expect(t, state == Gamepad_Exit_State{})
	testing.expect(t, !gamepad_exit_tick(&state, held, 0.3, true, true))
	testing.expect(t, !gamepad_exit_tick(&state, held, 1, true, false))
	testing.expect(t, state == Gamepad_Exit_State{})
	testing.expect(t, !gamepad_exit_tick(&state, held, 0.9, true, true))
	state = {}
	testing.expect(t, !gamepad_exit_tick(&state, held, 0.2, true, true), "a round reset begins a new hold")
	engine := Engine{gamepad_exit_state=state}
	testing.expect(t, !engine.gamepad_exit_disabled, "exit is enabled by default")
	set_gamepad_exit(&engine, false)
	testing.expect(t, engine.gamepad_exit_disabled && engine.gamepad_exit_state == Gamepad_Exit_State{})
	set_gamepad_exit(&engine, true)
	testing.expect(t, !engine.gamepad_exit_disabled && engine.gamepad_exit_state == Gamepad_Exit_State{})
	set_gamepad_exit(nil, false)
}

@(test)
quit_console_command_requires_engine_and_rejects_arguments :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	engine := Engine{console=console.init()}
	register_debug_commands(&engine.console)
	testing.expect(t, console.execute(&engine.console, "quit"))
	testing.expect(t, !engine.exit_requested && engine.console.error_count == 1, "an unattached console cannot close an engine")
	bind_debug_console(&engine, nil)
	testing.expect(t, console.execute(&engine.console, "quit unexpected"))
	testing.expect(t, !engine.exit_requested && engine.console.error_count == 2)
	testing.expect(t, console.execute(&engine.console, "quit"))
	testing.expect(t, engine.exit_requested && engine.console.error_count == 2)
	result, object_ok := engine.console.result_data.(json.Object)
	if testing.expect(t, object_ok) {
		testing.expect(t, result["exit_requested"].(json.Boolean))
	}
}

@(test)
quit_remote_reply_survives_early_loop_exit :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	directory, directory_error := os.make_directory_temp("", "rune-quit-*", context.allocator)
	if !testing.expect(t, directory_error == nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	request_path := fmt.tprintf("%s/exit.cmd", directory)
	result_path := fmt.tprintf("%s/exit.result.json", directory)
	defer os.remove(request_path)
	defer os.remove(result_path)
	engine := Engine{console=console.init()}
	register_debug_commands(&engine.console)
	bind_debug_console(&engine, nil)
	if !testing.expect(t, console.enable_remote(&engine.console, directory)) {return}
	if !testing.expect(t, os.write_entire_file(request_path, string("quit")) == nil) {return}
	console.poll_remote(&engine.console, 0)
	testing.expect(t, engine.exit_requested && engine.console.remote.result_len > 0)
	finish_exit_console(&engine)
	testing.expect(t, engine.console.remote.result_len == 0)
	data, read_error := os.read_entire_file(result_path, context.allocator)
	if !testing.expect(t, read_error == nil) {return}
	defer delete(data)
	result: json.Value
	if !testing.expect(t, json.unmarshal(data, &result) == nil) {return}
	defer json.destroy_value(result)
	object := result.(json.Object)
	testing.expect(t, object["ok"].(json.Boolean))
	testing.expect(t, object["data"].(json.Object)["exit_requested"].(json.Boolean), "remote quit is acknowledged before frame memory and window shutdown")
}
