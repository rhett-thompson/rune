package console

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

Batch_Test_Inbox :: struct {directory, request, reply, single, single_reply: string}
batch_test_inbox :: proc() -> Batch_Test_Inbox {
	assert(ensure_directory("build"))
	directory, err := os.make_directory_temp("build", "console-batch-*", context.allocator)
	assert(err == nil)
	return {directory, fmt.aprintf("%s/test.batch", directory), fmt.aprintf("%s/test.result.json", directory),
		fmt.aprintf("%s/single.cmd", directory), fmt.aprintf("%s/single.result.json", directory)}
}
batch_test_cleanup :: proc(inbox: Batch_Test_Inbox) {
	for path in ([]string{inbox.request, inbox.reply, inbox.single, inbox.single_reply}) {os.remove(path); delete(path)}
	os.remove(inbox.directory)
	delete(inbox.directory)
}
batch_test_record :: proc(dev: ^Console, arguments: string) {
	calls := cast(^int)dev.user_data
	calls^ += 1
	info(dev, arguments)
	set_result(dev, struct {call: int, nested: []string}{calls^, {arguments}})
}
batch_test_read :: proc(inbox: Batch_Test_Inbox) -> Remote_Batch_Result {
	bytes, err := os.read_entire_file(inbox.reply, context.temp_allocator)
	assert(err == nil)
	result: Remote_Batch_Result
	assert(json.unmarshal(bytes, &result, allocator = context.temp_allocator) == nil)
	return result
}

@(test)
batch_keeps_owned_results_and_dispatches_once_per_frame_without_poll_delay :: proc(t: ^testing.T) {
	inbox := batch_test_inbox()
	defer batch_test_cleanup(inbox)
	frame: mem.Dynamic_Arena
	mem.dynamic_arena_init(&frame)
	defer mem.dynamic_arena_destroy(&frame)
	context.temp_allocator = mem.dynamic_arena_allocator(&frame)
	dev := init()
	defer stop_remote(&dev)
	calls := 0
	dev.user_data = &calls
	assert(register(&dev, "record", "Record a result", batch_test_record))
	assert(enable_remote(&dev, inbox.directory))
	input := strings.builder_make(context.temp_allocator)
	for index in 0..<300 {fmt.sbprintf(&input, "record value-%d\n", index)}
	assert(os.write_entire_file(inbox.request, strings.to_string(input)) == nil)
	for index in 0..<300 {
		poll_remote(&dev, f64(index)/60)
		testing.expect(t, calls == index + 1, "one queued command dispatches per frame, even within 100 ms")
		poll_remote(&dev, f64(index)/60)
		testing.expect(t, calls == index + 1, "a pending command cannot dispatch twice")
		if index == 0 {
			assert(os.write_entire_file(inbox.single, "record stray") == nil)
			testing.expect(t, !execute(&dev, "record interloper"), "direct callers cannot interleave a batch")
			copy(dev.input[:], "record interactive")
			dev.input_len = len("record interactive")
			submit(&dev)
			testing.expect(t, calls == 1 && dev.input_len == len("record interactive"))
		}
		testing.expect(t, !os.exists(inbox.reply), "the reply is only published after the final entry")
		finish_remote(&dev)
		finish_remote(&dev) // A second finish in the same frame cannot duplicate an entry.
		testing.expect(t, os.exists(inbox.single), "a stray single request stays queued throughout the batch")
		mem.dynamic_arena_reset(&frame)
		// Reuse scratch and overwrite the whole log ring, invalidating borrowed storage.
		for _ in 0..<70 {info(&dev, fmt.tprintf("unrelated-frame-%d", index))}
	}
	result := batch_test_read(inbox)
	testing.expect(t, result.ok && result.complete && result.requested == 300 && result.completed == 300)
	testing.expect(t, len(result.results) == 300 && dev.remote.batch == nil && dev.remote.result_len == 0)
	for entry, index in result.results {
		testing.expect(t, entry.command == fmt.tprintf("record value-%d", index))
		testing.expect(t, entry.ok && entry.lines[1] == fmt.tprintf("value-%d", index))
		data := entry.data.(json.Object)
		testing.expect(t, data["call"].(json.Integer) == i64(index + 1))
		testing.expect(t, data["nested"].(json.Array)[0].(json.String) == json.String(fmt.tprintf("value-%d", index)))
	}
	poll_remote(&dev, 5)
	finish_remote(&dev)
	testing.expect(t, calls == 301 && !os.exists(inbox.single) && os.exists(inbox.single_reply))
}

@(test)
batch_parses_bom_crlf_and_continues_after_command_errors :: proc(t: ^testing.T) {
	inbox := batch_test_inbox()
	defer batch_test_cleanup(inbox)
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	defer stop_remote(&dev)
	calls := 0
	dev.user_data = &calls
	assert(register(&dev, "record", "Record", batch_test_record))
	assert(enable_remote(&dev, inbox.directory))
	long: [Max_Input_Length+1]u8
	for &byte in long {byte = 'x'}
	text := fmt.tprintf("\xef\xbb\xbf # comment\r\n\r\nrecord café\r\nmissing\n%s\nrecord bad\x00value\nrecord last\nrecord bare\r", string(long[:]))
	assert(os.write_entire_file(inbox.request, text) == nil)
	for index in 0..<6 {poll_remote(&dev, f64(index)/60); finish_remote(&dev)}
	result := batch_test_read(inbox)
	testing.expect(t, result.complete && !result.ok && result.completed == 6 && calls == 2)
	testing.expect(t, result.results[0].command == "record café" && result.results[0].ok)
	testing.expect(t, !result.results[1].ok && !result.results[2].ok && !result.results[3].ok)
	testing.expect(t, result.results[2].lines[0] == "Command exceeds 256 bytes.")
	testing.expect(t, result.results[4].ok && result.results[4].lines[1] == "last")
	testing.expect(t, !result.results[5].ok && result.results[5].lines[0] == "Expected one command line.")
}

@(test)
batch_rejects_file_limits_before_any_dispatch_and_accepts_empty :: proc(t: ^testing.T) {
	inbox := batch_test_inbox()
	defer batch_test_cleanup(inbox)
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	defer stop_remote(&dev)
	calls := 0
	dev.user_data = &calls
	assert(register(&dev, "record", "Record", batch_test_record))
	assert(enable_remote(&dev, inbox.directory))
	too_large := make([]u8, Max_Batch_Bytes+1, context.temp_allocator)
	for &byte in too_large {byte = 'x'}
	too_many := make([]u8, Max_Batch_Lines+1, context.temp_allocator)
	for &byte in too_many {byte = '\n'}
	for text, index in ([]string{string(too_large), string(too_many), "record valid\n\xff"}) {
		assert(os.write_entire_file(inbox.request, text) == nil)
		poll_remote(&dev, f64(index))
		result := batch_test_read(inbox)
		testing.expect(t, !result.ok && !result.complete && result.requested == 0 && result.completed == 0)
		testing.expect(t, len(result.results) == 0 && result.error != "" && calls == 0 && dev.remote.batch == nil)
		os.remove(inbox.reply)
	}
	for text, index in ([]string{"", "\xef\xbb\xbf", "  \r\n # ignored\n\t", string(too_many[:Max_Batch_Lines])}) {
		assert(os.write_entire_file(inbox.request, text) == nil)
		poll_remote(&dev, f64(index + 4))
		result := batch_test_read(inbox)
		testing.expect(t, result.ok && result.complete && result.requested == 0 && result.completed == 0)
		testing.expect(t, len(result.results) == 0 && result.error == "" && calls == 0)
		bytes, _ := os.read_entire_file(inbox.reply, context.temp_allocator)
		testing.expect(t, strings.contains(string(bytes), `"results":[]`), "empty results must be an array")
		os.remove(inbox.reply)
	}
}

@(test)
batch_clear_preserves_previous_results_and_resets_log_snapshot :: proc(t: ^testing.T) {
	inbox := batch_test_inbox()
	defer batch_test_cleanup(inbox)
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	defer stop_remote(&dev)
	calls := 0
	dev.user_data = &calls
	assert(register(&dev, "record", "Record", batch_test_record))
	assert(enable_remote(&dev, inbox.directory))
	assert(os.write_entire_file(inbox.request, "record first\nclear\nlogs\nrecord last") == nil)
	for index in 0..<4 {
		poll_remote(&dev, f64(index)/60)
		finish_remote(&dev)
		mem.dynamic_arena_reset(&scratch)
	}
	result := batch_test_read(inbox)
	testing.expect(t, result.ok && result.completed == 4)
	testing.expect(t, result.results[0].lines[1] == "first" && len(result.results[1].lines) == 0)
	logs := result.results[2].data.(json.Object)["entries"].(json.Array)
	testing.expect(t, len(logs) == 1 && logs[0].(json.Object)["message"].(json.String) == "> logs")
	testing.expect(t, result.results[3].lines[1] == "last")
}

@(test)
batch_reply_failure_releases_ownership_without_replaying :: proc(t: ^testing.T) {
	inbox := batch_test_inbox()
	defer batch_test_cleanup(inbox)
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	defer stop_remote(&dev)
	calls := 0
	dev.user_data = &calls
	assert(register(&dev, "record", "Record", batch_test_record))
	assert(enable_remote(&dev, inbox.directory))
	assert(os.make_directory(inbox.reply) == nil) // Deliberately obstruct final rename.
	assert(os.write_entire_file(inbox.request, "record once") == nil)
	poll_remote(&dev, 0)
	finish_remote(&dev)
	testing.expect(t, dev.remote.batch == nil && dev.remote.result_len == 0 && dev.error_count == 1)
	testing.expect(t, !os.exists(fmt.tprintf("%s.tmp", inbox.reply)))
	poll_remote(&dev, 1)
	testing.expect(t, calls == 1 && !os.exists(inbox.request), "a failed reply must not replay the claimed command")
}
