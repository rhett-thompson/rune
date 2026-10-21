package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "rune:pathutil"

content_test_root :: proc(t: ^testing.T) -> string {
	testing.expect(t, os.make_directory_all("build") == nil || os.is_directory("build"))
	root, error := os.make_directory_temp("build", "publisher-content-*", context.allocator)
	testing.expect(t, error == nil)
	absolute, absolute_error := pathutil.absolute(root)
	testing.expect(t, absolute_error == nil)
	return absolute
}

content_test_cleanup :: proc(root: string) {
	build, _ := pathutil.absolute("build")
	assert(root != build && publisher_path_is_within(build, root))
	content_test_remove_tree(root)
}

// Use deterministic no-follow recursion instead of the Windows shell operation
// used by remove_all. lstat keeps cleanup from traversing link targets.
content_test_remove_tree :: proc(path: string) {
	info, error := os.lstat(path, context.allocator)
	assert(error == nil)
	if info.type == .Directory {
		entries, read_error := os.read_all_directory_by_path(path, context.allocator)
		assert(read_error == nil)
		for entry in entries {child, _ := filepath.join({path, entry.name}); content_test_remove_tree(child)}
	}
	assert(os.remove(path) == nil)
}

content_test_write :: proc(t: ^testing.T, root, relative, text: string) {
	path, _ := filepath.join({root, relative})
	parent, _ := filepath.split(path)
	testing.expect(t, os.make_directory_all(parent) == nil || os.is_directory(parent))
	testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil, relative)
}

content_test_game :: proc(t: ^testing.T, root: string) {
	content_test_write(t, root, "project.json", `{"name":"Content test","window":{},"startup_scene":"scenes/main.scene.json"}`)
	content_test_write(t, root, "scenes/main.scene.json", `{"name":"Main","entities":[]}`)
}

@(test)
content_collects_copies_and_validates_package :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets/nested/custom data.json", `{"absolute_string":"C:/game data","path":"../custom"}`)
	content_test_write(t, root, "licenses/game.txt", "Game notice")
	testing.expect(t, os.make_directory(fmt.aprintf("%s/assets/empty", root)) == nil)
	config := Config{content={"project.json", "scenes/", "assets/"}, licenses={"licenses/game.txt"}}
	files, error := collect_content(root, config, "game.exe")
	testing.expect(t, error == "", error)
	testing.expect(t, len(files) == 5)
	stage, _ := filepath.join({root, "stage"})
	testing.expect(t, os.make_directory(stage) == nil)
	testing.expect(t, copy_publish_files(files, stage) == "")
	testing.expect(t, os.is_directory(fmt.aprintf("%s/assets/empty", stage)))
	testing.expect(t, validate_staged_project(stage) == "")
	testing.expect(t, copy_publish_files(files, stage) != "", "copy must not overwrite existing package files")
}

@(test)
content_rejects_escapes_missing_overlap_case_and_reserved_paths :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets/item.bin", "item")
	content_test_write(t, root, "manifest.json", "reserved")
	content_test_write(t, root, "licenses/rune/custom.txt", "reserved namespace")
	content_test_write(t, root, "game.exe", "reserved executable")
	for paths in ([]([]string){
		{"project.json", "missing/"}, {"project.json", "../outside"},
		{"project.json", "/absolute"}, {"project.json", `C:\absolute`},
		{"project.json", "assets/", "assets/item.bin"},
		{"project.json", "assets/", "ASSETS/"},
		{"project.json", "manifest.json"}, {"project.json", "licenses/"},
		{"project.json", "game.exe"}, {"assets/"},
	}) {
		_, error := collect_content(root, Config{content=paths}, "game.exe")
		testing.expect(t, error != "", fmt.aprintf("accepted invalid includes: %v", paths))
	}
	testing.expect(t, publisher_path_is_within(root, fmt.aprintf("%s/child", root)))
	testing.expect(t, !publisher_path_is_within(root, fmt.aprintf("%s-sibling/file", root)))
}

@(test)
content_validates_code_loaded_scenes_and_prefab_relative_assets :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets/image.png", "image")
	content_test_write(t, root, "prefabs/thing.prefab.json", `{"name":"Thing","components":{"SpriteRenderer":{"texture":"prefab://../assets/image.png"}}}`)
	content_test_write(t, root, "scenes/main.scene.json", `{"name":"Main","entities":[{"id":"thing","prefab":"../prefabs/thing.prefab.json"}]}`)
	testing.expect(t, validate_staged_project(root) == "", "contained prefab:// assets must resolve from the authoring file")
	content_test_write(t, root, "scenes/code-loaded.json", `{"name":"Other","entities":[{"id":"x","components":{"SpriteRenderer":{"texture":"assets/not-included.png"}}}]}`)
	error := validate_staged_project(root)
	testing.expect(t, strings.contains(error, "not-included.png"), error)
}

@(test)
content_rejects_authored_external_references_and_wrong_case :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets/image.png", "image")
	for reference in ([]string{"../outside.png", "/absolute.png", "C:/absolute.png", "assets/IMAGE.png", "prefab://../../outside.png"}) {
		text := fmt.aprintf(`{"name":"Main","entities":[{"components":{"SpriteRenderer":{"texture":"%s"}}}]}`, reference)
		content_test_write(t, root, "scenes/main.scene.json", text)
		error := validate_staged_project(root)
		testing.expect(t, error != "", reference)
	}
	// Absolute references to a real source file must not pass through validation.
	path := content_slashes(fmt.aprintf("%s/assets/image.png", root))
	content_test_write(t, root, "scenes/main.scene.json", fmt.aprintf(`{"name":"Main","entities":[{"components":{"SpriteRenderer":{"texture":"%s"}}}]}`, path))
	testing.expect(t, validate_staged_project(root) != "")
}

@(test)
content_checks_material_animation_terrain_and_model_sidecars :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets/model.gltf", `{"asset":{"version":"2.0"},"buffers":[{"uri":"model.bin"}],"images":[{"uri":"tex%20one.png"}]}`)
	content_test_write(t, root, "assets/model.bin", "buffer")
	content_test_write(t, root, "assets/tex one.png", "texture")
	testing.expect(t, validate_staged_project(root) == "")
	content_test_write(t, root, "assets/model.obj", "mtllib model.mtl\nv 0 0 0\n")
	testing.expect(t, strings.contains(validate_staged_project(root), "model.mtl"))
	content_test_write(t, root, "assets/model.mtl", "newmtl test\nmap_Kd tex one.png\n")
	testing.expect(t, validate_staged_project(root) == "")
	content_test_write(t, root, "assets/test.material.json", `{"normal":"../external.png"}`)
	testing.expect(t, strings.contains(validate_staged_project(root), "external.png"))
	testing.expect(t, os.remove(fmt.aprintf("%s/assets/test.material.json", root)) == nil)
	content_test_write(t, root, "assets/test.animation.json", `{"texture":"missing-animation.png"}`)
	testing.expect(t, strings.contains(validate_staged_project(root), "missing-animation.png"))
	testing.expect(t, os.remove(fmt.aprintf("%s/assets/test.animation.json", root)) == nil)
	content_test_write(t, root, "assets/test.terrain.json", `{"heightmap":"missing-heightmap.r16"}`)
	testing.expect(t, strings.contains(validate_staged_project(root), "missing-heightmap.r16"))
}

@(test)
content_rejects_symlink_files_directories_and_ancestors :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		context.allocator = mem.dynamic_arena_allocator(&arena)
		root := content_test_root(t)
		defer content_test_cleanup(root)
		content_test_game(t, root)
		content_test_write(t, root, "assets/real/file.bin", "real")
		link := fmt.aprintf("%s/linked", root)
		testing.expect(t, os.symlink(fmt.aprintf("%s/assets/real", root), link) == nil)
		_, error := collect_content(root, Config{content={"project.json", "linked/file.bin"}}, "game")
		testing.expect(t, error != "", "linked ancestors must be rejected")
		_, error = collect_content(root, Config{content={"project.json", "linked/"}}, "game")
		testing.expect(t, error != "", "linked directories must be rejected")
		testing.expect(t, os.remove(link) == nil)
		testing.expect(t, os.symlink(fmt.aprintf("%s/assets/real/file.bin", root), link) == nil)
		_, error = collect_content(root, Config{content={"project.json", "linked"}}, "game")
		testing.expect(t, error != "", "linked files must be rejected")
	}
}
