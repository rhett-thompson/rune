package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import win32 "core:sys/windows"

run_compiler :: proc(args: []string, cwd, rune_root: string) -> (string, string) {
	// The pinned Windows compiler's command_line_to_wargv removes every double
	// quote, including backslash-escaped ones; there is no literal-quote syntax.
	// Reject these values before spawning instead of silently changing a define
	// or linker flag. Linux's argv handling does preserve literal double quotes.
	for arg in args {
		if strings.contains(arg, `"`) {return "", "The pinned Windows Odin compiler cannot preserve literal double quotes in compiler arguments; remove double quotes from string defines or extra_linker_flags."}
	}
	discovery, _ := filepath.join({rune_root, "tools", "find_msvc.bat"})
	toolset, discovery_error := run_capture({"cscript.exe", "//nologo", "//E:JScript", discovery, "x64"}, rune_root)
	if discovery_error != "" {return "", discovery_error}
	environment, env_error := os.environ(context.allocator)
	if env_error != nil {return "", fmt.aprintf("Could not read the compiler environment: %v", env_error)}
	compiler_env := make([dynamic]string, 0, len(environment)+1)
	for variable in environment {
		key, _, _ := strings.partition(variable, "=")
		if !strings.equal_fold(key, "VCToolsInstallDir") {append(&compiler_env, variable)}
	}
	append(&compiler_env, fmt.aprintf("VCToolsInstallDir=%s", strings.trim_space(toolset)))
	directory := os.get_env("TEMP", context.allocator)
	if directory == "" {return "", "TEMP must be set for Rune's compiler lock."}
	path, _ := filepath.join({directory, "rune-odin-compile.lock"})
	wide := win32.utf8_to_wstring(path, context.allocator)
	attributes := win32.SECURITY_ATTRIBUTES{nLength = size_of(win32.SECURITY_ATTRIBUTES), bInheritHandle = true}
	handle := win32.INVALID_HANDLE_VALUE
	waiting := false
	for {
		handle = win32.CreateFileW(wide, win32.GENERIC_WRITE, win32.FILE_SHARE_READ, &attributes,
			win32.OPEN_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, nil)
		if handle != win32.INVALID_HANDLE_VALUE {break}
		error := win32.GetLastError()
		if error != win32.ERROR_SHARING_VIOLATION && error != win32.ERROR_LOCK_VIOLATION {
			return "", fmt.aprintf("Could not acquire compiler lock %s (Windows error %d).", path, error)
		}
		if !waiting {fmt.eprintln("Waiting for another Rune Odin command to finish..."); waiting = true}
		time.sleep(100 * time.Millisecond)
	}
	defer win32.CloseHandle(handle)
	return run_capture(args, cwd, compiler_env[:])
}
