package console

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "rune:profile"

// An opt-in local file inbox: .cmd and .batch requests each receive one
// .result.json reply. Idle directory scans are limited to once per 100 ms;
// an active batch advances once per frame on the game thread.
Remote_Console :: struct {
	directory:     [Max_Path_Length]u8,
	directory_len: int,
	next_poll:     f64,
	result_path:   [Max_Path_Length]u8,
	result_len:    int,
	log_start:     u64,
	error_start:   u64,
	dispatched:    bool,
	batch:         ^Remote_Batch,
	batch_dispatch: bool,
}

Remote_Result :: struct {
	ok:    bool,
	lines: []string,
	data:  json.Value,
}

enable_remote :: proc(console: ^Console, directory: string) -> bool {
	when profile.Player_Build {return false}
	if len(directory) == 0 || len(directory) > Max_Path_Length - 100 ||
	   console.remote.directory_len > 0 {return false}
	if !ensure_directory(directory) {return false}
	copy(console.remote.directory[:], directory)
	console.remote.directory_len = len(directory)
	info(console, fmt.tprintf("Local console inbox: %s", directory))
	return true
}

poll_remote :: proc(console: ^Console, now: f64) {
	when profile.Player_Build {return}
	remote := &console.remote
	if remote.batch != nil {
		dispatch_batch(console)
		return
	}
	if console.defer_reply || remote.directory_len == 0 || remote.result_len > 0 || now < remote.next_poll {return}
	remote.next_poll = now + 0.1
	directory := string(remote.directory[:remote.directory_len])
	entries, read_error := os.read_directory_by_path(directory, -1, context.temp_allocator)
	if read_error != nil {return}
	for entry in entries {
		is_batch := strings.has_suffix(entry.name, ".batch")
		if entry.type != .Regular || (!is_batch && !strings.has_suffix(entry.name, ".cmd")) ||
		   len(entry.name) > 80 {continue}
		path, _ := filepath.join({directory, entry.name}, context.temp_allocator)
		file, open_error := os.open(path)
		if open_error != nil {continue}
		limit := Max_Batch_Bytes if is_batch else Max_Input_Length
		buffer := make([]u8, limit + 1, context.temp_allocator)
		count: int
		command_error: os.Error
		if is_batch {count, command_error = os.read_full(file, buffer)
		} else {count, command_error = os.read(file, buffer)}
		os.close(file)
		// Claim before execution prevents repeat polling, not republished retries.
		if os.remove(path) != nil {continue}
		suffix_length := 6 if is_batch else 4
		result_path := fmt.tprintf("%s.result.json", path[:len(path)-suffix_length])
		copy(remote.result_path[:], result_path)
		remote.result_len = len(result_path)
		remote.log_start = console.log_sequence
		remote.error_start = console.error_count
		remote.dispatched = false
		if is_batch {
			if command_error != nil && command_error != .EOF {
				reject_batch(console, "Could not read console batch.")
			} else {
				begin_batch(console, string(buffer[:count]))
			}
		} else if command_error != nil {
			error(console, "Could not read console command.")
		} else {
			remote.dispatched = execute(console, string(buffer[:count]))
		}
		return
	}
}

finish_remote :: proc(console: ^Console) {
	when profile.Player_Build {return}
	remote := &console.remote
	if console.defer_reply {return}
	defer console.result_data = {}
	if remote.result_len == 0 {return}
	if remote.batch != nil {
		finish_batch_entry(console)
		return
	}
	write_remote_reply(console, remote_result(console))
}

@(private)
remote_result :: proc(console: ^Console) -> Remote_Result {
	remote := &console.remote
	// Include this command's output and any deferred capture result. The console
	// is bounded, so a very verbose handler returns its latest 64 log lines.
	count := int(min(console.log_sequence - remote.log_start, u64(console.line_count)))
	lines := make([]string, count, context.temp_allocator)
	for index in 0..<count {
		line := &console.lines[(console.line_start + console.line_count - count + index) % Max_Log_Lines]
		lines[index] = string(line.text[:line.len])
	}
	return Remote_Result {
		ok = remote.dispatched && console.error_count == remote.error_start,
		lines = lines,
		data = console.result_data,
	}
}

@(private)
write_remote_reply :: proc(console: ^Console, result: any) {
	remote := &console.remote
	data, marshal_error := json.marshal(result, allocator = context.temp_allocator)
	path := string(remote.result_path[:remote.result_len])
	staging := fmt.tprintf("%s.tmp", path)
	if marshal_error != nil || os.write_entire_file(staging, data) != nil ||
	   os.rename(staging, path) != nil {
		error(console, "Could not write local console reply.")
		os.remove(staging)
	}
	remote.result_len = 0
}
