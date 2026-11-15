package pathutil

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

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

@(test)
modified_time_matches_os_and_detects_creation_and_removal :: proc(t: ^testing.T) {
	directory, error := os.make_directory_temp("", "rune-stamp-*", context.allocator)
	if !testing.expect(t, error == nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path, path_error := filepath.join({directory, "modèle.materials.json"})
	if !testing.expect(t, path_error == nil) {return}
	defer delete(path)
	defer os.remove(path)
	testing.expect_value(t, modified_time(path), i64(-1))
	testing.expect_value(t, modified_time(""), i64(-1))
	if !testing.expect(t, os.write_entire_file(path, `{}`) == nil) {return}
	expected, lookup_error := os.modification_time_by_path(path)
	if !testing.expect(t, lookup_error == nil) {return}
	testing.expect_value(t, modified_time(path), time.to_unix_nanoseconds(expected))

	// A lexically equivalent long path exercises the general OS path fallback.
	repeated := strings.repeat("./", 135)
	defer delete(repeated)
	long_path := strings.concatenate({directory, "/", repeated, "modèle.materials.json"})
	defer delete(long_path)
	long_expected, long_error := os.modification_time_by_path(long_path)
	if long_error == nil {testing.expect_value(t, modified_time(long_path), time.to_unix_nanoseconds(long_expected))}
	else {testing.expect_value(t, modified_time(long_path), i64(-1))}
	if !testing.expect(t, os.remove(path) == nil) {return}
	testing.expect_value(t, modified_time(path), i64(-1))
}
