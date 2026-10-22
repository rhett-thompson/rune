package main

import "core:fmt"
import win32 "core:sys/windows"

content_reparse_error :: proc(path: string) -> string {
	wide := win32.utf8_to_wstring(path, context.allocator)
	attributes := win32.GetFileAttributesW(wide)
	if attributes == win32.INVALID_FILE_ATTRIBUTES {return fmt.aprintf("cannot inspect Windows attributes: %s", path)}
	if attributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 {return fmt.aprintf("reparse points and junctions are not supported in publishing: %s", path)}
	return ""
}
