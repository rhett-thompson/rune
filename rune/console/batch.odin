package console

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "rune:profile"

Max_Batch_Bytes :: 1024 * 1024
Max_Batch_Lines :: 4096

Remote_Batch_Entry :: struct {
	command: string,
	ok: bool,
	lines: []string,
	data: json.Value,
}

Remote_Batch_Result :: struct {
	ok: bool,
	complete: bool,
	requested: int,
	completed: int,
	error: string,
	results: []Remote_Batch_Entry,
}

// Commands, logs, and nested JSON must outlive frame scratch and the log ring.
Remote_Batch :: struct {
	owner: mem.Allocator,
	arena: mem.Dynamic_Arena,
	commands: [dynamic]string,
	results: []Remote_Batch_Entry,
	completed: int,
	pending: bool,
	ok: bool,
}

@(private)
reject_batch :: proc(console: ^Console, message: string) {
	error(console, message)
	write_remote_reply(console, Remote_Batch_Result{
		error = message, results = make([]Remote_Batch_Entry, 0, context.temp_allocator),
	})
}

@(private)
begin_batch :: proc(console: ^Console, input: string) {
	if len(input) > Max_Batch_Bytes {
		reject_batch(console, fmt.tprintf("Batch exceeds %d bytes.", Max_Batch_Bytes))
		return
	}
	if !utf8.valid_string(input) {reject_batch(console, "Expected UTF-8 batch text."); return}
	// Accept the optional UTF-8 BOM emitted by common Windows editors.
	text := input
	if strings.has_prefix(text, "\xef\xbb\xbf") {text = text[3:]}
	physical_lines := 0
	for i in 0..<len(text) {
		if text[i] == '\n' {physical_lines += 1}
	}
	if len(text) > 0 && text[len(text)-1] != '\n' {physical_lines += 1}
	if physical_lines > Max_Batch_Lines {
		reject_batch(console, fmt.tprintf("Batch exceeds %d physical lines.", Max_Batch_Lines))
		return
	}
	batch := new(Remote_Batch)
	batch.owner = context.allocator
	mem.dynamic_arena_init(&batch.arena)
	allocator := mem.dynamic_arena_allocator(&batch.arena)
	batch.commands = make([dynamic]string, 0, physical_lines, allocator)
	owned := strings.clone(text, allocator)
	start := 0
	for end in 0..=len(owned) {
		if end < len(owned) && owned[end] != '\n' {continue}
		line := owned[start:end]
		// A bare CR is not a delimiter and must reach execute's validation.
		if end < len(owned) && len(line) > 0 && line[len(line)-1] == '\r' {line = line[:len(line)-1]}
		trimmed := strings.trim_space(line)
		if trimmed != "" && !strings.has_prefix(trimmed, "#") {append(&batch.commands, line)}
		start = end + 1
	}
	batch.results = make([]Remote_Batch_Entry, len(batch.commands), allocator)
	batch.ok = true
	console.remote.batch = batch
	if len(batch.commands) == 0 {finish_batch(console); return}
	dispatch_batch(console)
}

@(private)
dispatch_batch :: proc(console: ^Console) {
	remote := &console.remote
	batch := remote.batch
	if batch == nil || batch.pending || console.defer_reply {return}
	batch.pending = true
	remote.log_start = console.log_sequence
	remote.error_start = console.error_count
	remote.batch_dispatch = true
	defer remote.batch_dispatch = false
	remote.dispatched = execute(console, batch.commands[batch.completed])
}

@(private)
finish_batch_entry :: proc(console: ^Console) {
	batch := console.remote.batch
	if !batch.pending {return}
	result := remote_result(console)
	allocator := mem.dynamic_arena_allocator(&batch.arena)
	entry := &batch.results[batch.completed]
	entry.command = batch.commands[batch.completed]
	entry.ok = result.ok
	entry.lines = make([]string, len(result.lines), allocator)
	for line, index in result.lines {entry.lines[index] = strings.clone(line, allocator)}
	bytes, marshal_error := json.marshal(result.data, allocator = context.temp_allocator)
	if marshal_error != nil || json.unmarshal(bytes, &entry.data, allocator = allocator) != nil {
		entry.ok = false
		entry.data = {}
		message := "Could not retain console batch result."
		error(console, message)
		// Keep serialization failures visible in this entry's transcript too.
		lines := make([]string, min(len(entry.lines) + 1, Max_Log_Lines), allocator)
		kept := len(lines) - 1
		copy(lines[:kept], entry.lines[len(entry.lines)-kept:])
		lines[kept] = message
		entry.lines = lines
	}
	batch.ok = batch.ok && entry.ok
	batch.completed += 1
	batch.pending = false
	if batch.completed == len(batch.commands) {finish_batch(console)}
}

@(private)
finish_batch :: proc(console: ^Console, message: string = "") {
	batch := console.remote.batch
	complete := batch.completed == len(batch.commands)
	write_remote_reply(console, Remote_Batch_Result{
		ok = complete && batch.ok,
		complete = complete,
		requested = len(batch.commands),
		completed = batch.completed,
		error = message,
		results = batch.results[:batch.completed],
	})
	owner := batch.owner
	mem.dynamic_arena_destroy(&batch.arena)
	free(batch, owner)
	console.remote.batch = nil
}

// Finalize before loop teardown, including exits between batch entries. This
// does not dispatch queued work. Custom console loops must call it on exit.
stop_remote :: proc(console: ^Console) {
	when profile.Player_Build {return}
	// Teardown callers need not have an active frame scratch allocator.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	if console.defer_reply || console.capture.len > 0 {
		console.defer_reply = false
		console.capture = {}
		console.result_data = {}
		error(console, "Engine stopped before the command completed.")
	}
	finish_remote(console)
	if console.remote.batch != nil {
		finish_batch(console, "Engine stopped before the batch completed.")
	}
}
