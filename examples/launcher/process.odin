package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// Arguments are passed directly to process_start, never through a shell.
// Quotes group spaces; backslash escapes whitespace, quotes and backslash.
// Other backslashes stay literal, including ordinary Windows path separators.
parse_example_args :: proc(value: string, allocator := context.allocator) -> (args: [dynamic]string, ok: bool) {
	args = make([dynamic]string, allocator)
	word := make([dynamic]u8, allocator)
	defer delete(word)
	quote: u8
	started := false
	for i := 0; i < len(value); i += 1 {
		character := value[i]
		if character == '\\' && quote != '\'' && i + 1 < len(value) {
			next := value[i + 1]
			if next == '\\' || next == '"' || next == '\'' || next == ' ' || next == '\t' {
				append(&word, next)
				i += 1
				started = true
				continue
			}
		}
		if quote != 0 {
			if character == quote {quote = 0} else {append(&word, character)}
			continue
		}
		if character == '"' || character == '\'' {quote = character; started = true; continue}
		if character == ' ' || character == '\t' || character == '\n' || character == '\r' {
			if started {
				append(&args, strings.clone(string(word[:]), allocator) or_else "")
				clear(&word)
				started = false
			}
			continue
		}
		append(&word, character)
		started = true
	}
	if quote != 0 {free_example_args(args, allocator); return nil, false}
	if started {append(&args, strings.clone(string(word[:]), allocator) or_else "")}
	return args, true
}

free_example_args :: proc(args: [dynamic]string, allocator := context.allocator) {
	for arg in args {delete(arg, allocator)}
	delete(args)
}

odin_on_path :: proc(path: string, allocator := context.temp_allocator) -> bool {
	if path == "" {return false}
	entries := strings.split(path, ";" when ODIN_OS == .Windows else ":", allocator)
	defer delete(entries, allocator)
	for entry in entries {
		directory := strings.trim(entry, "\"")
		if directory == "" {directory = "."}
		filename := "odin.exe" when ODIN_OS == .Windows else "odin"
		candidate, _ := filepath.join({directory, filename}, allocator)
		defer delete(candidate, allocator)
		info, error := os.stat(candidate, allocator)
		if error != nil {continue}
		is_file := info.type == .Regular
		os.file_info_delete(info, allocator)
		if !is_file {continue}
		when ODIN_OS == .Windows {return true} else {
			candidate_c, _ := strings.clone_to_cstring(candidate, allocator)
			defer delete(candidate_c, allocator)
			if posix.access(candidate_c, {.X_OK}) == .OK {return true}
		}
	}
	return false
}

prebuilt_mode :: proc(override: string, compiler_available: bool) -> bool {
	return override == "1" || !compiler_available
}

// Returned command storage is caller-owned; strings use the given allocator.
// Pure construction lets tests verify both modes without opening a window.
example_command :: proc(example: Example, prebuilt: bool, args: []string, allocator := context.allocator) -> [dynamic]string {
	command := make([dynamic]string, allocator)
	suffix :: ".exe" when ODIN_OS == .Windows else ""
	if prebuilt {
		append(&command, fmt.tprintf("./build/%s%s", example.path, suffix))
	} else {
		append(&command, "odin", "run", fmt.tprintf("examples/%s", example.path), "-o:none", "-collection:rune=rune")
		when ODIN_OS == .Windows {append(&command, "-linker:msvc")}
		append(&command, fmt.tprintf("-out:build/%s%s", example.path, suffix))
		for collection in example.collections {
			append(&command, fmt.tprintf("-collection:%s=%s", collection.name, collection.path))
		}
		if len(args) > 0 {append(&command, "--")}
	}
	append(&command, ..args)
	for arg, index in command {command[index] = strings.clone(arg, allocator) or_else ""}
	return command
}
