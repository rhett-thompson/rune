package pathutil

import "core:os"
import "core:time"

// Return the file's modification time in Unix nanoseconds, or -1 when it
// cannot be read. Follow links and retain the standard OS path semantics.
@(require_results)
modified_time :: proc(path: string) -> i64 {
	when ODIN_OS == .Windows {
		if stamp, handled := modified_time_windows(path); handled {return stamp}
	}
	modified, err := os.modification_time_by_path(path)
	if err != nil {return -1}
	return time.to_unix_nanoseconds(modified)
}
