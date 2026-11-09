package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "rune:pathutil"

main_test_root :: proc(t: ^testing.T) -> string {
	directory := "build"
	// Exercise actual Unix mode bits on a Linux filesystem. A Windows-backed
	// WSL checkout can report every file executable despite a successful chmod.
	when ODIN_OS == .Linux {directory = "/tmp"}
	if !testing.expect(t, os.make_directory_all(directory) == nil || os.is_directory(directory)) {return ""}
	root, error := os.make_directory_temp(directory, "publisher-main-*", context.allocator)
	if !testing.expect(t, error == nil) {return ""}
	absolute, absolute_error := pathutil.absolute(root)
	testing.expect(t, absolute_error == nil)
	return absolute
}

main_test_cleanup :: proc(root: string) {
	directory := "build"
	when ODIN_OS == .Linux {directory = "/tmp"}
	build, error := pathutil.absolute(directory)
	assert(error == nil && root != build && publisher_path_is_within(build, root))
	main_test_remove_tree(root)
}

main_test_remove_tree :: proc(root: string) {
	info, error := os.lstat(root, context.allocator)
	assert(error == nil)
	if info.type == .Directory {
		entries, read_error := os.read_all_directory_by_path(root, context.allocator)
		assert(read_error == nil)
		for entry in entries {
			path, _ := filepath.join({root, entry.name})
			main_test_remove_tree(path)
		}
	}
	assert(os.remove(root) == nil)
}

main_test_write :: proc(t: ^testing.T, root, relative, text: string) -> string {
	path, _ := filepath.join({root, relative})
	parent, _ := filepath.split(path)
	testing.expect(t, os.make_directory_all(parent) == nil || os.is_directory(parent))
	testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil)
	return path
}

main_test_has_arg :: proc(args: []string, expected: string) -> bool {
	for arg in args {if arg == expected {return true}}
	return false
}

when ODIN_OS == .Windows {
	@(test)
	main_windows_zip_preserves_binary_content_and_empty_directories :: proc(t: ^testing.T) {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		context.allocator = mem.dynamic_arena_allocator(&arena)
		context.temp_allocator = context.allocator
		root := main_test_root(t)
		if root == "" {return}
		defer main_test_cleanup(root)

		payload := "\x00\x1a\xff\r\n"
		_ = main_test_write(t, root, "Game Package/assets/data.bin", payload)
		empty, _ := filepath.join({root, "Game Package/assets/empty"})
		if !testing.expect(t, os.make_directory(empty) == nil) {return}
		archive, _ := filepath.join({root, "package.zip"})
		zip_error := create_windows_zip(archive, root, "Game Package")
		if !testing.expect(t, zip_error == "", zip_error) {return}

		extracted, _ := filepath.join({root, "extracted"})
		if !testing.expect(t, os.make_directory(extracted) == nil) {return}
		_, extract_error := run_capture({"tar.exe", "-xf", archive, "-C", extracted}, root)
		if !testing.expect(t, extract_error == "", extract_error) {return}
		file, _ := filepath.join({extracted, "Game Package/assets/data.bin"})
		data, read_error := os.read_entire_file(file, context.allocator)
		testing.expect(t, read_error == nil && string(data) == payload)
		extracted_empty, _ := filepath.join({extracted, "Game Package/assets/empty"})
		testing.expect(t, os.is_directory(extracted_empty))
	}
}

@(test)
main_options_validate_flags_and_preserve_argument_values :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	options, error := parse_options({"--project", "Game With Spaces", "--output", "Release Folder", "--target", "linux-amd64", "--rune-root", "Engine Root", "--odin", "Compiler Path", "--glibc-max", "2.35"})
	if testing.expect(t, error == "", error) {
		testing.expect(t, options.project == "Game With Spaces" && options.output == "Release Folder")
		testing.expect(t, options.target == "linux-amd64" && options.rune_root == "Engine Root" && options.compiler == "Compiler Path" && options.glibc_max == "2.35")
	}
	defaults, defaults_error := parse_options(nil)
	testing.expect(t, defaults_error == "" && defaults.project == "." && defaults.target == Current_Target)
	for args in ([]([]string){
		{"--unknown"}, {"--project"}, {"--output", ""}, {"--target"}, {"--odin"}, {"--glibc-max"},
		{"--project", "one", "--project", "two"}, {"--target", "windows-amd64", "--target", "linux-amd64"},
	}) {
		_, error := parse_options(args)
		testing.expect(t, error != "", fmt.aprintf("must reject arguments: %v", args))
	}
	help, help_error := parse_options({"--help"})
	testing.expect(t, help_error == "" && help.help)
	dry_run, dry_run_error := parse_options({"--dry-run"})
	testing.expect(t, dry_run_error == "" && dry_run.dry_run)
	_, duplicate_error := parse_options({"--dry-run", "--dry-run"})
	testing.expect(t, duplicate_error != "")
}

@(test)
main_dry_run_validates_content_without_compiler_or_output :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root := main_test_root(t)
	if root == "" {return}
	defer main_test_cleanup(root)
	content_test_game(t, root)
	_ = main_test_write(t, root, "engine/rune/core/core.odin", "")
	engine, _ := filepath.join({root, "engine"})
	output, _ := filepath.join({root, "output"})
	config := config_test_replace(`{"id":"dry-run","name":"Dry run","version":"1","executable":"dry-run","targets":["$target"]}`, "$target", Current_Target)
	_ = main_test_write(t, root, "publish.json", config)
	options := Options{project=root, rune_root=engine, target=Current_Target, compiler="must-not-launch-a-compiler", output=output, dry_run=true, glibc_max="2.39"}
	missing_catalog := publish(options)
	testing.expect(t, strings.contains(missing_catalog, "assets.json"), missing_catalog)
	content_test_write(t, root, "assets.json", `{"version":1,"assets":{"runtime":"missing.txt"}}`)
	missing_asset := publish(options)
	testing.expect(t, strings.contains(missing_asset, "missing.txt"), missing_asset)
	content_test_write(t, root, "missing.txt", "runtime file")
	publish_error := publish(options)
	testing.expect(t, publish_error == "", publish_error)
	content_test_write(t, root, "scenes/main.scene.json", `{"name":"Missing","entities":[{"components":{"SpriteRenderer":{"texture":"missing.png"}}}]}`)
	missing_reference := publish(options)
	testing.expect(t, strings.contains(missing_reference, "missing.png"), missing_reference)
	testing.expect(t, !path_is_present(output) && !path_is_present(fmt.aprintf("%s%s", output, Archive_Suffix)))
}

@(test)
main_publish_output_precedence :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root := main_test_root(t)
	if root == "" {return}
	defer main_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets.json", `{"version":1,"assets":{}}`)
	_ = main_test_write(t, root, "engine/rune/core/core.odin", "")
	engine, _ := filepath.join({root, "engine"})
	override, _ := filepath.join({root, "manual", "custom"})
	package_name := fmt.aprintf("my-game-0.1.0+1-%s", Current_Target)
	configured := config_test_replace(CONFIG_TEST_BASE, `"targets":`, `"output_directory":"Release Builds/dist/","targets":`)
	for test in ([]struct{config, override, expected: string}{
		{CONFIG_TEST_BASE, "", fmt.aprintf("build/publish/%s", package_name)},
		{configured, "", fmt.aprintf("Release Builds/dist/%s", package_name)},
		{configured, override, "manual/custom"},
	}) {
		_ = main_test_write(t, root, "publish.json", test.config)
		// An existing archive at the expected path stops before the compiler.
		archive := main_test_write(t, root, fmt.aprintf("%s%s", test.expected, Archive_Suffix), "existing")
		options := Options{project=root, rune_root=engine, target=Current_Target, compiler="must-not-launch-a-compiler", output=test.override, glibc_max="2.39"}
		error := publish(options)
		expected := archive[:len(archive)-len(Archive_Suffix)]
		testing.expect(t, error == fmt.aprintf("Output or archive already exists; choose a new directory: %s", expected), error)
	}
}

@(test)
main_compiler_argv_preserves_paths_and_typed_values :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	config := Config{build={collections=make(map[string]string), defines=make(map[string]json.Value), extra_linker_flags="-lm -ldl"}}
	config.build.collections["shared"] = "../Shared Code"
	config.build.collections["local"] = "third_party/local"
	config.build.defines["BOOLEAN"] = true
	config.build.defines["INTEGER"] = i64(-17)
	config.build.defines["FRACTION"] = f64(0.5)
	config.build.defines["TITLE"] = string(`spaces "quotes" back\slash $dollar &ampersand`)
	config.build.defines["STRING_BOOL"] = string("true")
	config.build.defines["STRING_NUMBER"] = string("123")
	config.build.defines["EMPTY"] = string("")
	game_root, _ := pathutil.absolute("build/My Game")
	rune_root, _ := pathutil.absolute("build/Rune Engine")
	binary, _ := filepath.join({game_root, "release", "My Game.exe"})
	args := compiler_command("Compiler Path/odin", game_root, rune_root, binary, config)
	testing.expect(t, len(args) >= 18 && args[0] == "Compiler Path/odin" && args[1] == "build" && args[2] == game_root)
	for expected in ([]string{"-o:speed", "-define:RUNE_PLAYER=true", "-define:RAYLIB_SHARED=false", "-define:BOOLEAN=true", "-define:INTEGER=-17", "-define:TITLE='spaces \"quotes\" back\\slash $dollar &ampersand'", "-define:STRING_BOOL='true'", "-define:STRING_NUMBER='123'", "-define:EMPTY=''", "-extra-linker-flags:-lm -ldl"}) {
		testing.expect(t, main_test_has_arg(args, expected), expected)
	}
	float_found := false
	for arg in args {
		if strings.has_prefix(arg, "-define:FRACTION=") {
			float_found = true
			text := arg[len("-define:FRACTION="):]
			number, parsed := strconv.parse_f64(text)
			testing.expect(t, parsed && number == 0.5 && strings.contains_any(text, ".eE"), arg)
		}
	}
	testing.expect(t, float_found)
	shared, _ := filepath.join({game_root, "../Shared Code"})
	testing.expect(t, main_test_has_arg(args, fmt.aprintf("-collection:shared=%s", shared)))
	testing.expect(t, main_test_has_arg(args, fmt.aprintf("-collection:rune=%s/rune", rune_root)))
	testing.expect(t, main_test_has_arg(args, fmt.aprintf("-collection:r3d=%s/third_party/r3d-odin", rune_root)))
	testing.expect(t, main_test_has_arg(args, fmt.aprintf("-out:%s", binary)))
	when ODIN_OS == .Windows {
		testing.expect(t, main_test_has_arg(args, "-linker:msvc"))
		testing.expect(t, main_test_has_arg(args, "-subsystem:windows"), "published players must not create a Windows console")
	} else {
		testing.expect(t, !main_test_has_arg(args, "-subsystem:windows"))
	}
	player_flags, static_flags := 0, 0
	for arg in args {
		if strings.has_prefix(arg, "-define:RUNE_PLAYER=") {player_flags += 1; testing.expect(t, arg == "-define:RUNE_PLAYER=true")}
		if strings.has_prefix(arg, "-define:RAYLIB_SHARED=") {static_flags += 1; testing.expect(t, arg == "-define:RAYLIB_SHARED=false")}
	}
	testing.expect(t, player_flags == 1 && static_flags == 1)
}

@(test)
main_package_records_hashes_sorted_paths_sizes_and_modes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root := main_test_root(t)
	if root == "" {return}
	defer main_test_cleanup(root)
	abc := main_test_write(t, root, "z.file", "abc")
	empty := main_test_write(t, root, "nested/a.bin", "")
	when ODIN_OS == .Linux {testing.expect(t, os.chmod(abc, {.Read_User, .Write_User, .Execute_User}) == nil)}
	abc_hash, hash_error := hash_file(abc)
	testing.expect(t, hash_error == "" && abc_hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	testing.expect(t, hash_bytes([]u8{'a', 'b', 'c'}) == abc_hash)
	empty_hash, empty_error := hash_file(empty)
	testing.expect(t, empty_error == "" && empty_hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	testing.expect(t, hash_bytes(nil) == empty_hash)
	_, missing_error := hash_file(fmt.aprintf("%s/missing", root))
	testing.expect(t, missing_error != "")
	records, record_error := record_package(root)
	if !testing.expect(t, record_error == "" && len(records) == 2, record_error) {return}
	testing.expect(t, records[0].path == "nested/a.bin" && records[0].size == 0 && records[0].sha256 == empty_hash)
	testing.expect(t, records[1].path == "z.file" && records[1].size == 3 && records[1].sha256 == abc_hash)
	info, stat_error := os.stat(abc, context.allocator)
	testing.expect(t, stat_error == nil && records[1].executable == (.Execute_User in info.mode))
	when ODIN_OS == .Linux {testing.expect(t, records[1].executable && !records[0].executable)}
	// Publication records the inventory before writing its own manifest. The
	// recorded snapshot therefore never hashes a manifest into itself.
	_ = main_test_write(t, root, "manifest.json", `{"files":[]}`)
	testing.expect(t, len(records) == 2 && records[0].path != "manifest.json" && records[1].path != "manifest.json")
}

@(test)
main_output_parent_rejects_included_directories_and_links :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root := main_test_root(t)
	if root == "" {return}
	defer main_test_cleanup(root)
	_ = main_test_write(t, root, "project.json", "{}")
	_ = main_test_write(t, root, "assets/asset.txt", "asset")
	_ = main_test_write(t, root, "licenses/game.txt", "notice")
	included_directories := []string{"assets", "licenses"}
	for relative in ([]string{"assets", "assets/releases/nested", "licenses", "licenses/packages"}) {
		parent, _ := filepath.join({root, relative})
		testing.expect(t, check_output_parent(parent, root, included_directories) != "", relative)
	}
	for relative in ([]string{"build/publish", "assets-other/packages", "licenses-sibling/packages"}) {
		parent, _ := filepath.join({root, relative})
		testing.expect(t, check_output_parent(parent, root, included_directories) == "", relative)
	}
	file_parent, _ := filepath.join({root, "project.json", "child"})
	testing.expect(t, check_output_parent(file_parent, root, included_directories) != "", "an existing regular file cannot be an output ancestor")
	when ODIN_OS == .Linux {
		assets, _ := filepath.join({root, "assets"})
		alias, _ := filepath.join({root, "alias"})
		if testing.expect(t, os.symlink(assets, alias) == nil) {
			defer os.remove(alias)
			parent, _ := filepath.join({alias, "nested"})
			testing.expect(t, check_output_parent(parent, root, included_directories) != "", "linked output ancestors are rejected")
		}
	}
}

@(test)
main_finalization_moves_files_and_directories_without_replacing_targets :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root := main_test_root(t)
	if root == "" {return}
	defer main_test_cleanup(root)
	_ = main_test_write(t, root, "staged-game/nested/content.txt", "packaged content")
	archive := main_test_write(t, root, "staged-archive", "archive bytes")
	stage, _ := filepath.join({root, "staged-game"})
	game, _ := filepath.join({root, "published-game"})
	package_archive, _ := filepath.join({root, "published-archive"})
	// Real publication records the staged inventory immediately before moving.
	// Pinned Windows core:os Walker destruction leaks its final search handle;
	// this catches a regression to an inventory traversal that blocks the move.
	records, record_error := record_package(stage)
	testing.expect(t, record_error == "" && len(records) == 1, record_error)
	testing.expect(t, finalize_new_path(stage, game) == "")
	testing.expect(t, !path_is_present(stage) && os.is_directory(game))
	content, content_error := os.read_entire_file(fmt.aprintf("%s/nested/content.txt", game), context.allocator)
	testing.expect(t, content_error == nil && string(content) == "packaged content")
	testing.expect(t, finalize_new_path(archive, package_archive) == "")
	testing.expect(t, !path_is_present(archive) && path_is_present(package_archive))
	for directory in ([2]bool{false, true}) {
		source, destination: string
		if directory {
			source, _ = filepath.join({root, "source-directory"})
			destination, _ = filepath.join({root, "existing-directory"})
			_ = main_test_write(t, source, "data", "source bytes")
			_ = main_test_write(t, destination, "data", "existing bytes")
		} else {
			source = main_test_write(t, root, "source-file", "source bytes")
			destination = main_test_write(t, root, "existing-file", "existing bytes")
		}
		testing.expect(t, finalize_new_path(source, destination) != "", "existing outputs must be preserved")
		if directory {source, _ = filepath.join({source, "data"}); destination, _ = filepath.join({destination, "data"})}
		source_bytes, source_error := os.read_entire_file(source, context.allocator)
		destination_bytes, destination_error := os.read_entire_file(destination, context.allocator)
		testing.expect(t, source_error == nil && string(source_bytes) == "source bytes")
		testing.expect(t, destination_error == nil && string(destination_bytes) == "existing bytes")
	}
}

@(test)
main_windows_compiler_rejects_unrepresentable_literal_quotes :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		context.allocator = mem.dynamic_arena_allocator(&arena)
		context.temp_allocator = context.allocator
		// Rejection precedes both compiler lock acquisition and child creation,
		// so this deliberately nonexistent compiler must never be looked up.
		output, error := run_compiler({"nonexistent-publisher-test-compiler", "build", `-define:TITLE='literal "quote"'`}, ".", ".")
		testing.expect(t, output == "" && strings.contains(error, "cannot preserve literal double quotes"))
	}
}
