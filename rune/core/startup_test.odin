package core

import "core:os"
import "core:path/filepath"
import "core:testing"
import "rune:pathutil"

@(test)
portable_project_paths_follow_executable_layout :: proc(t: ^testing.T) {
	directory, directory_error := os.get_executable_directory(context.allocator)
	if !testing.expect(t, directory_error == nil) {return}
	defer delete(directory)
	for path in ([]string{Default_Project_Path, "content/project.json", "../a game/project.json"}) {
		joined, _ := filepath.join({directory, path})
		expected, _ := pathutil.absolute(joined)
		actual, error := executable_project_path(path)
		testing.expect(t, error == nil && filepath.is_abs(actual))
		testing.expect_value(t, actual, expected)
		delete(actual)
		delete(expected)
		delete(joined)
	}
	actual, error := executable_project_path()
	testing.expect(t, error == nil)
	defer delete(actual)
	explicit, _ := executable_project_path(Default_Project_Path)
	defer delete(explicit)
	testing.expect_value(t, actual, explicit)
	when Player_Build {
		testing.expect_value(t, Default_Project_Path, "project.json")
	} else {
		testing.expect_value(t, Default_Project_Path, "../project.json")
	}
}

@(test)
resource_paths_share_the_absolute_project_root :: proc(t: ^testing.T) {
	root, _ := pathutil.absolute("a relocated game/content")
	defer delete(root)
	engine := Engine{project_directory = root}
	actual, error := resource_path(&engine, "models/../textures/player.png")
	expected, _ := filepath.join({root, "textures/player.png"})
	defer delete(actual)
	defer delete(expected)
	testing.expect(t, error == nil)
	testing.expect_value(t, actual, expected)
	// Explicit absolute paths are never prefixed a second time.
	absolute, absolute_error := executable_project_path(expected)
	resource, resource_error := resource_path(&engine, expected)
	defer delete(absolute)
	defer delete(resource)
	testing.expect(t, absolute_error == nil && resource_error == nil)
	testing.expect_value(t, absolute, expected)
	testing.expect_value(t, resource, expected)
	for invalid in ([]^Engine{nil, &Engine{}}) {
		_, invalid_error := resource_path(invalid, "texture.png")
		testing.expect(t, invalid_error != nil, "an unresolved root must not fall back to CWD")
	}
}
