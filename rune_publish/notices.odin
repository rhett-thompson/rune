package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

notice_file :: proc(files: ^[dynamic]Publish_File, root, relative, namespace: string) -> string {
	source, join_error := filepath.join([]string{root, relative})
	if join_error != nil {return "cannot allocate notice path"}
	info, stat_error := os.lstat(source, context.allocator)
	if stat_error != nil || info.type != .Regular || info.size == 0 {
		return fmt.aprintf("missing required engine/toolchain notice: %s", source)
	}
	append(files, Publish_File{source = source, destination = fmt.aprintf("licenses/rune/%s%s", namespace, relative)})
	return ""
}

// Box3D includes dependency notices inside its source headers rather than a
// standalone license file. Preserve the tree, matching Rune's staging workflow.
notice_tree :: proc(files: ^[dynamic]Publish_File, root, relative, namespace: string) -> string {
	source, join_error := filepath.join([]string{root, relative})
	if join_error != nil {return "cannot allocate notice directory path"}
	info, stat_error := os.lstat(source, context.allocator)
	if stat_error != nil || info.type != .Directory {return fmt.aprintf("missing required notice directory: %s", source)}
	entries, read_error := os.read_all_directory_by_path(source, context.allocator)
	if read_error != nil {return fmt.aprintf("cannot read notice directory: %s: %v", source, read_error)}
	for entry in entries {
		next := fmt.aprintf("%s/%s", relative, entry.name)
		child, _ := filepath.join([]string{root, next})
		child_info, child_error := os.lstat(child, context.allocator)
		if child_error != nil {return fmt.aprintf("cannot inspect notice input: %s", child)}
		failure := ""
		#partial switch child_info.type {
		case .Directory: failure = notice_tree(files, root, next, namespace)
		case .Regular: failure = notice_file(files, root, next, namespace)
		case: return fmt.aprintf("notice input must be a regular file or directory (symlinks are unsupported): %s", child)
		}
		if failure != "" {return failure}
	}
	return ""
}

// Collect conservatively even when a game does not import an optional renderer
// or UI module. These notices cover engine inputs, not the game's asset rights.
collect_engine_notices :: proc(rune_root, odin_root: string) -> ([]Publish_File, string) {
	files: [dynamic]Publish_File
	for relative in ([]string{
		"LICENSE", "THIRD_PARTY.md", "third_party/clay/LICENSE.md",
		"third_party/r3d-odin/LICENSE", "third_party/r3d-importer/LICENSE.assimp",
		"third_party/r3d-importer/LICENSE.r3d", "third_party/r3d-importer/LICENSE.raylib",
		"third_party/r3d-importer/LICENSE.raymath", "third_party/r3d-importer/LICENSE.uthash",
		"third_party/r3d-importer/README.md", "third_party/r3d-shadows/README.md",
		"third_party/rune-image/LICENSE.stb_image", "third_party/rune-image/README.md",
		"third_party/rune-image/sources.json", "third_party/rune-image/thread-local-png-error.patch",
	}) {
		if failure := notice_file(&files, rune_root, relative, ""); failure != "" {return nil, failure}
	}
	for relative in ([]string{"LICENSE", "vendor/raylib/LICENSE", "vendor/box2d/LICENSE", "vendor/stb/src/stb_image.h"}) {
		if failure := notice_file(&files, odin_root, relative, "odin/"); failure != "" {return nil, failure}
	}
	// These files carry Box3D's original notices and embedded third-party code.
	for required in ([]string{"vendor/box3d/src/include/box3d/box3d.h", "vendor/box3d/src/src/verstable.h"}) {
		path, _ := filepath.join([]string{odin_root, required})
		if !os.is_file(path) {return nil, fmt.aprintf("missing required Box3D notice source: %s", path)}
	}
	if failure := notice_tree(&files, odin_root, "vendor/box3d/src", "odin/"); failure != "" {return nil, failure}
	return files[:], ""
}
