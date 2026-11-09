package main

import "core:fmt"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"

create_windows_zip :: proc(archive, workspace, leaf: string) -> string {
	file, open_error := os.open(archive, {.Write, .Create, .Excl})
	if open_error != nil {return fmt.aprintf("Could not create ZIP: %v", open_error)}
	defer os.close(file)

	// A pipe keeps bsdtar's self-archive check from comparing a staged entry
	// against the ZIP using file IDs that can collide on Windows filesystems.
	reader, writer, pipe_error := os.pipe()
	if pipe_error != nil {return fmt.aprintf("Could not open ZIP pipe: %v", pipe_error)}
	defer os.close(reader)
	process, start_error := os.process_start({
		command = {"tar.exe", "--format=zip", "-cf", "-", "-C", workspace, "--", leaf},
		working_dir = workspace, stdout = writer, stderr = os.stderr,
	})
	os.close(writer)
	if start_error != nil {return fmt.aprintf("Could not run tar.exe: %v", start_error)}

	buffer: [64 * 1024]byte = ---
	copy_error: os.Error
	for {
		n, read_error := os.read(reader, buffer[:])
		if read_error == .EOF || read_error == .Broken_Pipe {break}
		if read_error != nil {copy_error = read_error; break}
		_, copy_error = os.write(file, buffer[:n])
		if copy_error != nil {break}
	}
	// Stop the producer before waiting if we can no longer drain the pipe.
	if copy_error != nil {_ = os.process_kill(process)}
	state, wait_error := os.process_wait(process)
	if copy_error != nil {return fmt.aprintf("Could not write ZIP stream: %v", copy_error)}
	if wait_error != nil {return fmt.aprintf("Could not wait for tar.exe: %v", wait_error)}
	if !state.exited || state.exit_code != 0 {return fmt.aprintf("tar.exe failed (exit %d)", state.exit_code)}
	return ""
}

finalize_new_path :: proc(source, destination: string) -> string {
	from := publish_windows_path(source)
	to := publish_windows_path(destination)
	// No REPLACE_EXISTING: works for directories and refuses a target that
	// appears after preflight instead of replacing someone else's output.
	if !win32.MoveFileExW(from, to, 0) {
		return fmt.aprintf("Windows move failed (error %d)", win32.GetLastError())
	}
	return ""
}

publish_windows_path :: proc(path: string) -> win32.wstring {
	native, _ := strings.replace_all(path, "/", "\\")
	if !strings.has_prefix(native, `\\?\`) {
		if strings.has_prefix(native, `\\`) {native = fmt.aprintf(`\\?\UNC\%s`, native[2:])} else {native = fmt.aprintf(`\\?\%s`, native)}
	}
	return win32.utf8_to_wstring(native, context.allocator)
}
