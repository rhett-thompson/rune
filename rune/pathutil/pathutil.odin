// Lexical absolute paths for both existing assets and future output files.
package pathutil

import "core:os"
import "core:path/filepath"

// Matches filepath.abs ownership and error conventions, but never resolves
// symlinks or requires the target to exist. Windows' native absolute-path API
// already has those semantics and also handles drive-relative and UNC paths.
@(require_results)
absolute :: proc(path: string, allocator := context.allocator) -> (string, os.Error) {
	when ODIN_OS == .Windows {
		return filepath.abs(path, allocator)
	} else {
		if filepath.is_abs(path) {
			cleaned, error := filepath.clean(path, allocator)
			return cleaned, error
		}
		directory, error := os.get_working_directory(allocator)
		if error != nil {return "", error}
		defer delete(directory, allocator)
		joined, join_error := filepath.join({directory, path}, allocator)
		return joined, join_error
	}
}
