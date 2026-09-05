package console

import "core:encoding/json"
import "core:strconv"
import "core:strings"

Frame_Metadata :: struct {
	frame: u64,
	simulation_time: f64,
	simulation_steps: u64,
	scene: string,
	camera_2d: string,
	camera_3d: string,
}

// Copies value into frame scratch storage, including nested strings. Deferred
// handlers must call this on their completion frame, before finish_remote.
set_result :: proc(console: ^Console, value: any) {
	data, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil || json.unmarshal(data, &console.result_data, allocator = context.temp_allocator) != nil {
		error(console, "Could not serialize command result.")
		return
	}
	if console.remote.result_len == 0 {
		for offset := 0; offset < len(data); offset += Max_Line_Length {
			info(console, string(data[offset:min(offset + Max_Line_Length, len(data))]))
		}
	}
}

Log_Entry :: struct {
	sequence: u64,
	level: string,
	message: string,
}

Log_Result :: struct {
	next_sequence: u64,
	oldest_sequence: u64,
	truncated: bool,
	entries: []Log_Entry,
}

// Copies the log into allocator so later console writes cannot overwrite it.
// The default snapshot expires at the end of the current frame.
read_logs :: proc(console: ^Console, since: u64, allocator := context.temp_allocator) -> Log_Result {
	entries := make([dynamic]Log_Entry, allocator)
	oldest := console.log_sequence + 1
	if console.line_count > 0 {oldest = console.lines[console.line_start].sequence}
	for index in 0..<console.line_count {
		line := &console.lines[(console.line_start + index) % Max_Log_Lines]
		if line.sequence <= since {continue}
		level := "info"
		if line.level == .Warning {level = "warning"}
		if line.level == .Error {level = "error"}
		message, _ := strings.clone(string(line.text[:line.len]), allocator)
		append(&entries, Log_Entry{line.sequence, level, message})
	}
	return {console.log_sequence, oldest, since < oldest - 1, entries[:]}
}

logs_command :: proc(console: ^Console, arguments: string) {
	since: u64
	if len(arguments) > 0 {
		value, ok := strconv.parse_uint(arguments, 10)
		if !ok {error(console, "Usage: logs [since-sequence]"); return}
		since = u64(value)
	}
	set_result(console, read_logs(console, since))
}
