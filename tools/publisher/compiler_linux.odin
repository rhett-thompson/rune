package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

run_compiler :: proc(args: []string, cwd: string) -> (string, string) {
	directory := os.get_env("TMPDIR", context.allocator)
	if directory == "" {directory = "/tmp"}
	lock, _ := filepath.join({directory, fmt.aprintf("rune-odin-compile-%d.lock", os.get_uid())})
	command := make([dynamic]string)
	append(&command, "flock", lock)
	append(&command, ..args)
	return run_capture(command[:], cwd)
}
