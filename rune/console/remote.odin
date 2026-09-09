package console

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// An opt-in local file inbox: one command per .cmd file, one .result.json
// reply. The sender publishes requests by atomic rename. No background thread
// touches game state; at most one request is dispatched per 100 ms on the loop.
Remote_Console :: struct {
	directory:     [Max_Path_Length]u8,
	directory_len: int,
	next_poll:     f64,
	result_path:   [Max_Path_Length]u8,
	result_len:    int,
	log_start:     u64,
	error_start:   u64,
	dispatched:    bool,
}

Remote_Result :: struct {
	ok:    bool,
	lines: []string,
	data:  json.Value,
}

enable_remote :: proc(console: ^Console, directory: string) -> bool {
	if len(directory) == 0 || len(directory) > Max_Path_Length - 100 ||
	   console.remote.directory_len > 0 {return false}
	if !ensure_directory(directory) {return false}
	copy(console.remote.directory[:], directory)
	console.remote.directory_len = len(directory)
	info(console, fmt.tprintf("Local console inbox: %s", directory))
	return true
}

poll_remote :: proc(console: ^Console, now: f64) {
	remote := &console.remote
	if console.defer_reply || remote.directory_len == 0 || remote.result_len > 0 || now < remote.next_poll {return}
	remote.next_poll = now + 0.1
	directory := string(remote.directory[:remote.directory_len])
	entries, read_error := os.read_directory_by_path(directory, -1, context.temp_allocator)
	if read_error != nil {return}
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".cmd") ||
		   len(entry.name) > 80 {continue}
		path, _ := filepath.join({directory, entry.name}, context.temp_allocator)
		file, open_error := os.open(path)
		if open_error != nil {continue}
		buffer: [Max_Input_Length + 1]u8
		count, command_error := os.read(file, buffer[:])
		os.close(file)
		// Claim before executing so retries never dispatch the same command twice.
		if os.remove(path) != nil {continue}
		result_path := fmt.tprintf("%s.result.json", path[:len(path)-4])
		copy(remote.result_path[:], result_path)
		remote.result_len = len(result_path)
		remote.log_start = console.log_sequence
		remote.error_start = console.error_count
		remote.dispatched = false
		if command_error != nil {
			error(console, "Could not read console command.")
		} else {
			remote.dispatched = execute(console, string(buffer[:count]))
		}
		return
	}
}

finish_remote :: proc(console: ^Console) {
	remote := &console.remote
	if console.defer_reply {return}
	defer console.result_data = {}
	if remote.result_len == 0 {return}
	// Include this command's output and any deferred capture result. The console
	// is bounded, so a very verbose handler returns its latest 64 log lines.
	count := int(min(console.log_sequence - remote.log_start, u64(console.line_count)))
	lines := make([]string, count, context.temp_allocator)
	for index in 0..<count {
		line := &console.lines[(console.line_start + console.line_count - count + index) % Max_Log_Lines]
		lines[index] = string(line.text[:line.len])
	}
	result := Remote_Result {
		ok = remote.dispatched && console.error_count == remote.error_start,
		lines = lines,
		data = console.result_data,
	}
	data, marshal_error := json.marshal(result, allocator = context.temp_allocator)
	path := string(remote.result_path[:remote.result_len])
	staging := fmt.tprintf("%s.tmp", path)
	if marshal_error != nil || os.write_entire_file(staging, data) != nil ||
	   os.rename(staging, path) != nil {
		error(console, "Could not write local console reply.")
	}
	remote.result_len = 0
}
