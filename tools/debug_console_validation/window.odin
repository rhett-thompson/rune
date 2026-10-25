package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "rune:console"
import rune "rune:core"
import rl "vendor:raylib"

validate_window_visibility_commands :: proc() {
	directory, err := os.make_directory_temp("build", "console-window-*", context.temp_allocator)
	assert(err == nil)
	defer os.remove(directory)
	request := fmt.tprintf("%s/request.batch", directory)
	defer os.remove(request)
	reply := fmt.tprintf("%s/request.result.json", directory)
	defer os.remove(reply)
	game := rune.Engine{console=console.init()}
	defer console.stop_remote(&game.console)
	rune.register_debug_commands(&game.console)
	rune.bind_debug_console(&game, nil)
	assert(console.enable_remote(&game.console, directory))
	assert(os.write_entire_file(request, "window hidden\nwindow fullscreen\nwindow\nwindow windowed\nwindow show") == nil)
	for frame in 0..<5 {
		console.poll_remote(&game.console, f64(frame)/60)
		assert(rune.window_mode() == .Windowed, "a queued fullscreen request must never apply before show")
		assert(rl.IsWindowHidden() == (frame < 4))
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		console.finish_frame(&game.console)
		rl.EndDrawing()
	}
	bytes, read_error := os.read_entire_file(reply, context.temp_allocator)
	assert(read_error == nil)
	result: console.Remote_Batch_Result
	assert(json.unmarshal(bytes, &result, allocator=context.temp_allocator) == nil)
	assert(result.ok && result.complete && result.completed == 5 && result.requested == 5)
	for entry, index in result.results {
		assert(entry.ok)
		data := entry.data.(json.Object)
		assert(data["hidden"].(json.Boolean) == (index < 4))
		assert(data["mode"].(json.String) == "windowed")
		expected := "fullscreen" if index == 1 || index == 2 else "windowed"
		assert(data["requested_mode"].(json.String) == json.String(expected))
	}
	assert(!game.window.hidden && !rl.IsWindowState({.WINDOW_ALWAYS_RUN}))
	fmt.println("Console window: hidden/show verbs and native/requested mode payloads passed through a batch")
}
