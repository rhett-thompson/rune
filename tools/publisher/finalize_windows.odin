package main

import "core:fmt"
import "core:strings"
import win32 "core:sys/windows"

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
