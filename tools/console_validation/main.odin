package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "rune:console"

calls: int
echo :: proc(dev: ^console.Console, arguments: string) {
	calls += 1
	console.info(dev, arguments)
}

main :: proc() {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	dev := console.init()
	assert(console.register(&dev, "echo", "Echo arguments", echo))
	copy(dev.input[:], "unfinished")
	dev.input_len = 10
	assert(console.execute(&dev, "echo hello world"))
	assert(calls == 1 && dev.input_len == 10 && string(dev.input[:10]) == "unfinished")
	assert(!console.execute(&dev, "missing"))
	assert(!console.execute(&dev, "echo one\necho two"))
	assert(console.execute(&dev, "capture build/captures/with spaces.png"))
	assert(string(dev.capture.path[:dev.capture.len]) == "build/captures/with spaces.png")
	errors := dev.error_count
	console.execute(&dev, "capture another.png")
	assert(dev.error_count == errors + 1)
	dev.capture = {}
	console.execute(&dev, "capture wrong.jpg")
	assert(dev.capture.len == 0)

	directory := fmt.tprintf("build/console-validation-%d", time.to_unix_nanoseconds(time.now()))
	assert(console.enable_remote(&dev, directory))
	defer os.remove(directory)
	// A game can restart with the same inbox; existing files are not directories.
	reused := console.init()
	assert(console.enable_remote(&reused, directory), "existing inbox directories must be reusable")
	collision := fmt.tprintf("%s/not-a-directory", directory)
	assert(os.write_entire_file(collision, "file") == nil)
	defer os.remove(collision)
	blocked := console.init()
	assert(!console.enable_remote(&blocked, collision), "a regular file cannot be an inbox")
	assert(!console.enable_remote(&blocked, fmt.tprintf("%s/child", collision)), "a parent file cannot be traversed")
	staging := fmt.tprintf("%s/request.tmp", directory)
	request := fmt.tprintf("%s/request.cmd", directory)
	reply := fmt.tprintf("%s/request.result.json", directory)
	defer os.remove(staging)
	defer os.remove(request)
	defer os.remove(reply)
	assert(os.write_entire_file(staging, "echo from inbox") == nil)
	console.poll_remote(&dev, 1)
	assert(calls == 1, "unpublished requests must not execute")
	assert(os.rename(staging, request) == nil)
	console.poll_remote(&dev, 1.05)
	assert(calls == 1, "inbox polling should be throttled")
	console.poll_remote(&dev, 2)
	assert(calls == 2)
	assert(!os.exists(request), "a request must be claimed exactly once")
	assert(!os.exists(reply), "reply must wait for end of frame")
	console.finish_remote(&dev)
	data, read_error := os.read_entire_file(reply, context.temp_allocator)
	assert(read_error == nil)
	result: console.Remote_Result
	assert(json.unmarshal(data, &result, allocator = context.temp_allocator) == nil)
	assert(result.ok && len(result.lines) == 2 && result.lines[1] == "from inbox")
	console.poll_remote(&dev, 3)
	assert(calls == 2, "completed commands must not replay")
	assert(os.remove(reply) == nil)
	assert(os.write_entire_file(request, "unknown_command") == nil)
	console.poll_remote(&dev, 4)
	console.finish_remote(&dev)
	data, read_error = os.read_entire_file(reply, context.temp_allocator)
	assert(read_error == nil)
	result = {}
	assert(json.unmarshal(data, &result, allocator = context.temp_allocator) == nil)
	assert(!result.ok && strings.has_prefix(result.lines[len(result.lines)-1], "Unknown command:"))
	assert(os.remove(reply) == nil)
	oversized: [console.Max_Input_Length + 1]u8
	for &byte in oversized {byte = 'x'}
	assert(os.write_entire_file(request, oversized[:]) == nil)
	console.poll_remote(&dev, 5)
	console.finish_remote(&dev)
	data, read_error = os.read_entire_file(reply, context.temp_allocator)
	assert(read_error == nil)
	result = {}
	assert(json.unmarshal(data, &result, allocator = context.temp_allocator) == nil)
	assert(!result.ok)
	fmt.println("Console command and local inbox validation passed")
}
