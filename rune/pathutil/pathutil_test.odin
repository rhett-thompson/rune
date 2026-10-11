package pathutil

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
absolute_accepts_future_paths :: proc(t: ^testing.T) {
	directory, error := os.get_working_directory(context.allocator)
	testing.expect(t, error == nil)
	defer delete(directory)
	expected, _ := filepath.join({directory, "not-created-rune-path", "save.json"})
	defer delete(expected)
	actual, path_error := absolute("not-created-rune-path/child/../save.json")
	testing.expect(t, path_error == nil)
	testing.expect_value(t, actual, expected)
	testing.expect(t, filepath.is_abs(actual))
	defer delete(actual)
	// Resolving the path must not create either a directory or a file.
	testing.expect(t, !os.exists(actual))
}

@(test)
absolute_normalizes_current_and_root_paths :: proc(t: ^testing.T) {
	directory, _ := os.get_working_directory(context.allocator)
	defer delete(directory)
	for path in ([]string{"", ".", "./child/.."}) {
		actual, error := absolute(path)
		testing.expect(t, error == nil)
		testing.expect_value(t, actual, directory)
		delete(actual)
	}
	when ODIN_OS == .Windows {
		for path in ([]string{`C:\future\..\save.json`, `\\server\share\future\..\save.json`, `C:future\..\save.json`, `\future\..\save.json`}) {
			expected, _ := filepath.abs(path)
			actual, error := absolute(path)
			testing.expect(t, error == nil)
			testing.expect_value(t, actual, expected)
			delete(actual)
			delete(expected)
		}
	} else {
		actual, error := absolute("/../../future//child/../save.json")
		testing.expect(t, error == nil)
		testing.expect_value(t, actual, "/future/save.json")
		delete(actual)
	}
}
