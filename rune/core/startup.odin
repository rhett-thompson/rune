package core

import "core:os"
import "core:path/filepath"
import "rune:pathutil"

// Generated development binaries live in GAME_ROOT/build/. Player binaries
// live beside project.json. Neither layout depends on the working directory.
when Player_Build {
	Default_Project_Path :: "project.json"
} else {
	Default_Project_Path :: "../project.json"
}

// Returns an owned absolute path, allocated with allocator. Relative paths
// resolve from the running executable, including an explicitly supplied layout.
// Absolute paths are preserved and normalized for tools with a known project.
// This does not search parent directories, change CWD, or require a file to exist.
@(require_results)
executable_project_path :: proc(path: string = Default_Project_Path, allocator := context.allocator) -> (string, os.Error) {
	if filepath.is_abs(path) {return pathutil.absolute(path, allocator)}
	directory, directory_error := os.get_executable_directory(context.allocator)
	if directory_error != nil {return "", directory_error}
	defer delete(directory)
	joined, join_error := filepath.join({directory, path}, context.allocator)
	if join_error != nil {return "", join_error}
	defer delete(joined)
	return pathutil.absolute(joined, allocator)
}

// Portable startup for generated games. init(path) remains available for
// callers that deliberately resolve a project from CWD or another location.
init_project :: proc(path: string = Default_Project_Path, defer_window_show: bool = false) -> (Engine, bool) {
	project_path, error := executable_project_path(path)
	if error != nil {return {}, false}
	defer delete(project_path)
	return init(project_path, defer_window_show)
}

// Resolve a path for custom game file I/O from the engine's resource root.
// Pass engine.project_directory to r3d_bridge.init for that same root.
// Returns an owned absolute path; this neither loads nor creates the file.
// Absolute paths and parent traversal remain available to tools; a future
// publisher must validate that distributed references stay inside its content.
@(require_results)
resource_path :: proc(engine: ^Engine, path: string, allocator := context.allocator) -> (string, os.Error) {
	if engine == nil || !filepath.is_abs(engine.project_directory) {return "", os.General_Error.Invalid_Dir}
	if filepath.is_abs(path) {return pathutil.absolute(path, allocator)}
	joined, join_error := filepath.join({engine.project_directory, path}, context.allocator)
	if join_error != nil {return "", join_error}
	defer delete(joined)
	return pathutil.absolute(joined, allocator)
}
