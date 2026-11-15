package pathutil

import "core:strings"
import win32 "core:sys/windows"

@(private)
modified_time_windows :: proc(path: string) -> (stamp: i64, handled: bool) {
	// Leave long path normalization and link resolution to core:os.
	buffer: [248]u16
	if path == "" || len(path) >= len(buffer) || strings.index_byte(path, 0) >= 0 {return}

	name := win32.utf8_to_wstring(buffer[:], path)
	if name == nil {return}
	attributes: win32.WIN32_FILE_ATTRIBUTE_DATA
	if !win32.GetFileAttributesExW(name, win32.GetFileExInfoStandard, &attributes) {
		switch win32.GetLastError() {
		case win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND: return -1, true
		}
		return
	}
	if attributes.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 {return}
	// A timestamp only needs the attributes. Full stat also resolves the
	// absolute name and may open the file to classify its type.
	return win32.FILETIME_as_unix_nanoseconds(attributes.ftLastWriteTime), true
}
