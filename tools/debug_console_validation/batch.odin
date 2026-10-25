package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "rune:console"
import rune "rune:core"
import rl "vendor:raylib"

// Called with the validator's hidden window. Both capture's before-overlay
// completion and profile's after-presentation completion must hold the queue.
validate_batch_capture_profile :: proc() {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	directory, err := os.make_directory_temp("build", "console-batch-runtime-*", context.allocator)
	assert(err == nil)
	defer delete(directory)
	defer os.remove(directory)
	request := fmt.aprintf("%s/request.batch", directory)
	defer delete(request)
	defer os.remove(request)
	reply := fmt.aprintf("%s/request.result.json", directory)
	defer delete(reply)
	defer os.remove(reply)
	capture := fmt.aprintf("%s/frame.png", directory)
	defer delete(capture)
	defer os.remove(capture)
	game := rune.Engine{console=console.init()}
	defer console.stop_remote(&game.console)
	rune.register_debug_commands(&game.console)
	rune.bind_debug_console(&game, nil)
	game.debug.paused = true
	assert(console.enable_remote(&game.console, directory))
	assert(os.write_entire_file(request, fmt.tprintf("status\ncapture %s\nprofile 3\nstatus", capture)) == nil)
	for frame in 1..=6 {
		game.console.result_data = {}
		game.console.frame_metadata = {}
		mem.dynamic_arena_reset(&arena)
		game.debug.frame = u64(frame)
		game.debug.frame_started = rl.GetTime()
		console.poll_remote(&game.console, f64(frame) / 60)
		if frame >= 3 && frame <= 5 {assert(game.console.defer_reply)}
		rl.BeginDrawing()
		rl.ClearBackground({20, 40, 80, 255})
		rl.DrawRectangle(100, 100, 50, 50, {230, 80, 40, 255})
		game.console.frame_metadata = rune.debug_frame_metadata(&game)
		console.finish_frame(&game.console)
		if frame < 6 {assert(!os.exists(reply), "the final reply waits for profile and the last status")}
		rl.EndDrawing()
		rune.debug_profile_finished_frame(&game)
		if frame >= 3 && frame < 5 {assert(game.console.defer_reply)}
		if frame == 5 {assert(!game.console.defer_reply && !os.exists(reply))}
	}
	data, read_error := os.read_entire_file(reply, context.temp_allocator)
	assert(read_error == nil)
	value: json.Value
	assert(json.unmarshal(data, &value, allocator=context.temp_allocator) == nil)
	object := value.(json.Object)
	assert(object["ok"].(json.Boolean) && object["complete"].(json.Boolean))
	assert(object["completed"].(json.Integer) == 4 && object["requested"].(json.Integer) == 4)
	entries := object["results"].(json.Array)
	assert(len(entries) == 4)
	assert(entries[0].(json.Object)["data"].(json.Object)["metadata"].(json.Object)["frame"].(json.Integer) == 1)
	captured := entries[1].(json.Object)["data"].(json.Object)
	assert(captured["metadata"].(json.Object)["frame"].(json.Integer) == 2)
	assert(captured["width"].(json.Integer) == i64(rl.GetRenderWidth()) && captured["height"].(json.Integer) == i64(rl.GetRenderHeight()))
	profile := entries[2].(json.Object)["data"].(json.Object)
	assert(profile["frames"].(json.Integer) == 3)
	assert(entries[3].(json.Object)["data"].(json.Object)["metadata"].(json.Object)["frame"].(json.Integer) == 6)
	capture_c, _ := strings.clone_to_cstring(capture, context.temp_allocator)
	image := rl.LoadImage(capture_c)
	assert(image.data != nil)
	defer rl.UnloadImage(image)
	assert(rl.GetImageColor(image, 10, 10) == rl.Color{20, 40, 80, 255})
	fmt.println("Console batch: rendered capture, profile completion boundaries, and cross-frame result ownership passed")
}
