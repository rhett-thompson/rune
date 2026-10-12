package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

// These parsers return slices into their input and require a whole log line.
// The managed server always binds IPv4 loopback with an OS-assigned port.
relay_endpoint_from_log :: proc(text: string) -> (string, bool) {
	prefix :: "Rune relay listening on "
	suffix :: " (TCP)"
	start := 0
	for index in 0..<len(text) {
		if text[index] != '\n' {continue}
		line := text[start:index]
		start = index + 1
		if strings.has_suffix(line, "\r") {line = line[:len(line)-1]}
		if len(line) < len(prefix) + len(suffix) ||
		   !strings.has_prefix(line, prefix) || !strings.has_suffix(line, suffix) {continue}
		value := line[len(prefix):len(line)-len(suffix)]
		if !strings.has_prefix(value, "127.0.0.1:") {continue}
		port := value[len("127.0.0.1:"):]
		if len(port) == 0 {continue}
		digits := true
		for character in port {if character < '0' || character > '9' {digits = false; break}}
		if !digits {continue}
		endpoint, valid := net.parse_endpoint(value)
		if !valid || endpoint.port < 1 || endpoint.port > 65535 {continue}
		address, ipv4 := endpoint.address.(net.IP4_Address)
		if !ipv4 || address != net.IP4_Loopback {continue}
		return value, true
	}
	return "", false
}

relay_room_from_log :: proc(text: string) -> (string, bool) {
	prefix :: "Room: "
	suffix :: " peer=1 role=host"
	start := 0
	for index in 0..<len(text) {
		if text[index] != '\n' {continue}
		line := text[start:index]
		start = index + 1
		if strings.has_suffix(line, "\r") {line = line[:len(line)-1]}
		if len(line) != len(prefix) + 16 + len(suffix) ||
		   !strings.has_prefix(line, prefix) || !strings.has_suffix(line, suffix) {continue}
		room := line[len(prefix):len(prefix)+16]
		valid := true
		for character in room {
			if !(character >= '0' && character <= '9') && !(character >= 'A' && character <= 'F') {
				valid = false
				break
			}
		}
		if valid {return room, true}
	}
	return "", false
}

// Like example_command, these commands own every string and can be released
// with free_example_args. Arguments remain separate; no shell is involved.
relay_build_command :: proc(package_path, output_path: string, collections: []Collection, allocator := context.allocator) -> [dynamic]string {
	command := make([dynamic]string, allocator)
	append(&command, "odin", "build", package_path, "-o:none", "-collection:rune=rune")
	when ODIN_OS == .Windows {append(&command, "-linker:msvc")}
	append(&command, fmt.tprintf("-out:%s", output_path))
	for collection in collections {
		append(&command, fmt.tprintf("-collection:%s=%s", collection.name, collection.path))
	}
	for arg, index in command {command[index] = strings.clone(arg, allocator) or_else ""}
	return command
}

relay_client_command :: proc(example: Example, endpoint, room: string, args: []string, allocator := context.allocator) -> [dynamic]string {
	command := make([dynamic]string, allocator)
	suffix :: ".exe" when ODIN_OS == .Windows else ""
	append(&command, fmt.tprintf("./build/%s%s", example.path, suffix))
	if room == "" {append(&command, "--host")} else {append(&command, "--join", room)}
	append(&command, "--server", endpoint)
	for arg in args {
		if strings.has_prefix(arg, "--console-dir=") {
			role := "relay-host" if room == "" else "relay-guest"
			append(&command, fmt.tprintf("--console-dir=%s/%s", arg[len("--console-dir="):], role))
		} else {
			append(&command, arg)
		}
	}
	for arg, index in command {command[index] = strings.clone(arg, allocator) or_else ""}
	return command
}

@(private="file")
Relay_Child :: struct {
	process: os.Process,
	active: bool, // False after a successful wait has reaped/closed the handle.
	exit_code: int,
	stdout_reader: ^os.File,
	startup_log: [64 * 1024]u8,
	startup_count: int,
}

@(private="file")
relay_poll_child :: proc(child: ^Relay_Child) -> string {
	if !child.active {return ""}
	state, error := os.process_wait(child.process, timeout = 0)
	if error == .Timeout {return ""}
	// On Windows any non-timeout wait also closes the process handle.
	child.active = false
	if error != nil {
		fmt.eprintf("Could not wait for relay session child pid=%d: %v\n", child.process.pid, error)
		return "Could not wait for a relay session process. See terminal and session logs."
	}
	child.exit_code = state.exit_code
	return ""
}

@(private="file")
relay_stop_child :: proc(child: ^Relay_Child) {
	if child.active {
		// process_terminate may broadcast Ctrl+C to a shared Windows console.
		// Kill only the exact process handle owned by this session instead.
		kill_error := os.process_kill(child.process)
		_, wait_error := os.process_wait(child.process, timeout = 2 * time.Second)
		if wait_error == .Timeout {
			kill_error = os.process_kill(child.process)
			_, wait_error = os.process_wait(child.process, timeout = 2 * time.Second)
		}
		if wait_error != nil {
			fmt.eprintf("Could not reap relay session child pid=%d: kill=%v wait=%v\n", child.process.pid, kill_error, wait_error)
		}
		child.active = false
	}
	if child.stdout_reader != nil {os.close(child.stdout_reader); child.stdout_reader = nil}
}

@(private="file")
relay_build :: proc(package_path, output_path: string, collections: []Collection) -> (int, string) {
	command := relay_build_command(package_path, output_path, collections)
	defer free_example_args(command)
	fmt.printf("Building %s...\n", package_path)
	process, start_error := os.process_start({command = command[:], stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if start_error != nil {
		fmt.eprintf("Could not start build of %s: %v\n", package_path, start_error)
		return -1, "Could not start a relay session build. See terminal for details."
	}
	child := Relay_Child{process = process, active = true}
	defer relay_stop_child(&child)
	for child.active {
		if error := relay_poll_child(&child); error != "" {return -1, error}
		if child.active {time.sleep(25 * time.Millisecond)}
	}
	if child.exit_code != 0 {
		fmt.eprintf("Build of %s exited with code %d\n", package_path, child.exit_code)
		return child.exit_code, "Relay session build failed. See terminal for details."
	}
	return 0, ""
}

@(private="file")
relay_start_child :: proc(child: ^Relay_Child, command: []string, directory, name: string) -> string {
	stdout_path := fmt.tprintf("%s/%s.stdout.log", directory, name)
	stderr_path := fmt.tprintf("%s/%s.stderr.log", directory, name)
	// Windows process_start requires inheritable redirected file handles.
	stdout, stdout_error := os.open(stdout_path, {.Write, .Create, .Trunc, .Inheritable})
	if stdout_error != nil {
		fmt.eprintf("Could not create %s: %v\n", stdout_path, stdout_error)
		return "Could not create relay session logs. See terminal for details."
	}
	defer os.close(stdout)
	stderr, stderr_error := os.open(stderr_path, {.Write, .Create, .Trunc, .Inheritable})
	if stderr_error != nil {
		fmt.eprintf("Could not create %s: %v\n", stderr_path, stderr_error)
		return "Could not create relay session logs. See terminal for details."
	}
	defer os.close(stderr)
	reader, read_error := os.open(stdout_path)
	if read_error != nil {
		fmt.eprintf("Could not open %s: %v\n", stdout_path, read_error)
		return "Could not read relay session logs. See terminal for details."
	}
	process, start_error := os.process_start({command = command, stdout = stdout, stderr = stderr})
	if start_error != nil {
		os.close(reader)
		fmt.eprintf("Could not start relay session %s: %v\n", name, start_error)
		return "Could not start a relay session process. See terminal and session logs."
	}
	child^ = {process = process, active = true, stdout_reader = reader}
	// The parent closes its writer handles on return. Each child keeps only
	// its own redirected logs; future children do not inherit those writers.
	return ""
}

@(private="file")
relay_read_startup_log :: proc(child: ^Relay_Child) -> string {
	if child.startup_count == len(child.startup_log) {
		return "Relay session startup log exceeded its limit. See session logs."
	}
	read, error := os.read(child.stdout_reader, child.startup_log[child.startup_count:])
	if read < 0 || read > len(child.startup_log) - child.startup_count {
		return "Could not read relay session startup log. See session logs."
	}
	child.startup_count += read
	if error != nil && error != .EOF {
		fmt.eprintf("Could not read relay session child pid=%d stdout: %v\n", child.process.pid, error)
		return "Could not read relay session startup log. See session logs."
	}
	return ""
}

run_relay_session :: proc(example: Example, prebuilt: bool, args: []string) -> (int, string) {
	// Validate before any build, filesystem, or process work. Both clients
	// must use the session's matching role, endpoint, and room invitation.
	for arg in args {
		switch arg {
		case "--host": return -1, "RUNE_EXAMPLE_ARGS cannot set --host for a managed relay session."
		case "--join": return -1, "RUNE_EXAMPLE_ARGS cannot set --join for a managed relay session."
		case "--server": return -1, "RUNE_EXAMPLE_ARGS cannot set --server for a managed relay session."
		case "--capture": return -1, "RUNE_EXAMPLE_ARGS cannot set --capture for two managed game clients."
		}
	}
	suffix :: ".exe" when ODIN_OS == .Windows else ""
	relay_path := fmt.tprintf("build/rune_relay%s", suffix)
	example_path := fmt.tprintf("build/%s%s", example.path, suffix)
	if prebuilt {
		if !os.exists(relay_path) || os.is_dir(relay_path) {
			fmt.eprintf("Missing prebuilt relay server: %s\n", relay_path)
			return -1, "Missing prebuilt relay server. Build or stage rune_relay first."
		}
		if !os.exists(example_path) || os.is_dir(example_path) {
			fmt.eprintf("Missing prebuilt relay example: %s\n", example_path)
			return -1, "Missing prebuilt relay example. Build or stage Relay Arena first."
		}
	}
	if error := os.make_directory_all("build"); error != nil && error != .Exist {
		return -1, "Could not create build directory for a relay session."
	}
	if !prebuilt {
		if code, error := relay_build("rune_relay", relay_path, nil); code != 0 || error != "" {return code, error}
		if code, error := relay_build(fmt.tprintf("examples/%s", example.path), example_path, example.collections); code != 0 || error != "" {return code, error}
	}
	directory, directory_error := os.make_directory_temp("build", "relay-session-*", context.allocator)
	if directory_error != nil {
		fmt.eprintf("Could not create relay session log directory: %v\n", directory_error)
		return -1, "Could not create relay session log directory. See terminal for details."
	}
	defer delete(directory)
	fmt.printf("Relay session logs: %s\n", directory)
	children: [3]Relay_Child
	defer {
		// End games before their server, and reap only handles we still own.
		relay_stop_child(&children[2])
		relay_stop_child(&children[1])
		relay_stop_child(&children[0])
	}
	server, host, guest := &children[0], &children[1], &children[2]
	server_command := []string{fmt.tprintf("./%s", relay_path), "--listen", "127.0.0.1:0"}
	if error := relay_start_child(server, server_command, directory, "server"); error != "" {return -1, error}
	endpoint := ""
	started := time.tick_now()
	for endpoint == "" {
		if error := relay_poll_child(server); error != "" {return -1, error}
		if !server.active {
			fmt.eprintf("Relay server exited before startup with code %d\n", server.exit_code)
			return 1, "Relay server exited before startup. See session logs."
		}
		if error := relay_read_startup_log(server); error != "" {return -1, error}
		if found, valid := relay_endpoint_from_log(string(server.startup_log[:server.startup_count])); valid {endpoint = found; break}
		if time.tick_since(started) >= 10 * time.Second {return -1, "Relay server startup timed out. See session logs."}
		time.sleep(25 * time.Millisecond)
	}
	fmt.printf("Relay session server: %s\n", endpoint)
	host_command := relay_client_command(example, endpoint, "", args)
	defer free_example_args(host_command)
	if error := relay_start_child(host, host_command[:], directory, "host"); error != "" {return -1, error}
	room := ""
	started = time.tick_now()
	for room == "" {
		if error := relay_poll_child(server); error != "" {return -1, error}
		if !server.active {return 1, "Relay server exited unexpectedly. See session logs."}
		if error := relay_poll_child(host); error != "" {return -1, error}
		if !host.active {
			fmt.eprintf("Relay host exited before creating a room with code %d\n", host.exit_code)
			return max(1, host.exit_code), "Relay host exited before creating a room. See session logs."
		}
		if error := relay_read_startup_log(host); error != "" {return -1, error}
		if found, valid := relay_room_from_log(string(host.startup_log[:host.startup_count])); valid {room = found; break}
		if time.tick_since(started) >= 15 * time.Second {return -1, "Relay host room creation timed out. See session logs."}
		time.sleep(25 * time.Millisecond)
	}
	fmt.printf("Relay session room: %s\n", room)
	guest_command := relay_client_command(example, endpoint, room, args)
	defer free_example_args(guest_command)
	if error := relay_start_child(guest, guest_command[:], directory, "guest"); error != "" {return -1, error}
	for host.active || guest.active {
		if error := relay_poll_child(server); error != "" {return -1, error}
		if !server.active {return 1, "Relay server exited unexpectedly. See session logs."}
		if error := relay_poll_child(host); error != "" {return -1, error}
		if error := relay_poll_child(guest); error != "" {return -1, error}
		if !host.active && host.exit_code != 0 {
			fmt.eprintf("Relay host exited with code %d\n", host.exit_code)
			return host.exit_code, "Relay host failed. See session logs."
		}
		if !guest.active && guest.exit_code != 0 {
			fmt.eprintf("Relay guest exited with code %d\n", guest.exit_code)
			return guest.exit_code, "Relay guest failed. See session logs."
		}
		if host.active || guest.active {time.sleep(25 * time.Millisecond)}
	}
	return 0, ""
}
