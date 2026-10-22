package main

import "core:fmt"
import "core:strings"
import "core:sys/linux"

finalize_new_path :: proc(source, destination: string) -> string {
	from, _ := strings.clone_to_cstring(source)
	to, _ := strings.clone_to_cstring(destination)
	if error := linux.renameat2(linux.AT_FDCWD, from, linux.AT_FDCWD, to, {.NOREPLACE}); error != nil {
		if error == .EINVAL || error == .ENOSYS || error == .EOPNOTSUPP {
			return "Output filesystem does not support atomic moves without replacement; choose --output on a native Linux filesystem (some WSL Windows mounts do not support this operation)."
		}
		return fmt.aprintf("Linux move without replacement failed: %v", error)
	}
	return ""
}
