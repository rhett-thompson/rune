package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "rune:console"
import rune "rune:core"
import rl "vendor:raylib"

// Exercise both rejection points through the actual inbox: hidden on dispatch,
// and visible on dispatch but hidden before the queued readback executes.
validate_hidden_capture_contract :: proc() {
	for queued in ([2]bool{false, true}) {
		directory, err := os.make_directory_temp("build", "console-hidden-capture-*", context.temp_allocator)
		assert(err == nil)
		defer os.remove(directory)
		request := fmt.tprintf("%s/request.batch", directory)
		defer os.remove(request)
		reply := fmt.tprintf("%s/request.result.json", directory)
		defer os.remove(reply)
		output_directory := fmt.tprintf("%s/absent", directory)
		capture := fmt.tprintf("%s/frame.png", output_directory)
		defer os.remove(capture)
		defer os.remove(output_directory)
		game := rune.Engine{console=console.init()}
		defer console.stop_remote(&game.console)
		rune.register_debug_commands(&game.console)
		rune.bind_debug_console(&game, nil)
		assert(console.enable_remote(&game.console, directory))
		assert(os.write_entire_file(request, fmt.tprintf("capture %s\nstatus", capture)) == nil)
		if queued {rl.ClearWindowState({.WINDOW_HIDDEN})}
		else {rl.SetWindowState({.WINDOW_HIDDEN})}
		assert(rl.IsWindowHidden() == !queued)
		console.poll_remote(&game.console, 0)
		assert((game.console.capture.len > 0) == queued)
		if queued {rl.SetWindowState({.WINDOW_HIDDEN})}
		assert(rl.IsWindowHidden())
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		console.finish_frame(&game.console)
		rl.EndDrawing()
		assert(game.console.capture.len == 0 && !game.console.defer_reply)
		assert(!os.exists(output_directory) && !os.exists(capture), "hidden capture must not touch the output path")
		assert(!os.exists(reply), "the following batch command remains queued for the next frame")
		game.debug.frame = 2
		console.poll_remote(&game.console, 1.0/60.0)
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		console.finish_frame(&game.console)
		rl.EndDrawing()
		assert(game.console.remote.batch == nil && game.console.remote.result_len == 0)
		bytes, read_error := os.read_entire_file(reply, context.temp_allocator)
		assert(read_error == nil)
		result: console.Remote_Batch_Result
		assert(json.unmarshal(bytes, &result, allocator=context.temp_allocator) == nil)
		assert(result.complete && !result.ok && result.requested == 2 && result.completed == 2)
		assert(!result.results[0].ok && result.results[1].ok)
		assert(result.results[0].data.(json.Object)["error"].(json.String) == "capture_window_hidden")
		assert(result.results[1].data.(json.Object)["metadata"].(json.Object)["frame"].(json.Integer) == 2)
		assert(game.console.error_count == 1, "each capture failure is reported exactly once")
	}
	fmt.println("Console capture: hidden dispatch and queued readback reject without files, and batches continue")
}
