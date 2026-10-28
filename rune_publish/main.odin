package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "rune:pathutil"

Current_Target :: "windows-amd64" when ODIN_OS == .Windows else "linux-amd64"
Executable_Suffix :: ".exe" when ODIN_OS == .Windows else ""
Archive_Suffix :: ".zip" when ODIN_OS == .Windows else ".tar.gz"

Options :: struct {
	project, output, target, rune_root, compiler, glibc_max: string,
	windows_runtime_directory, windows_runtime_license: string,
	help, dry_run: bool,
}
File_Record :: struct {path: string, size: i64, sha256: string, executable: bool}
Source_Revision :: struct {commit, state: string}
Manifest :: struct {
	format_version: int,
	id, name, version, target, executable, built_utc, compiler, config_sha256: string,
	rune_source, game_source: Source_Revision,
	profile: string,
	configuration: Config,
	native_sources: map[string]json.Value,
	native: Native_Audit,
	files: []File_Record,
	asset_pruning: Prune_Report,
}

main :: proc() {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	code := run_main(os.args[1:])
	mem.dynamic_arena_destroy(&arena)
	if code != 0 {os.exit(code)}
}

parse_options :: proc(args: []string) -> (Options, string) {
	options := Options{project = ".", target = Current_Target, compiler = "odin", glibc_max = "2.39"}
	if compiler := os.get_env("ODIN", context.allocator); compiler != "" {options.compiler = compiler}
	seen := make(map[string]bool)
	for i := 0; i < len(args); i += 1 {
		key := args[i]
		if key == "--help" || key == "-h" {options.help = true; continue}
		if seen[key] {return {}, fmt.aprintf("Duplicate option: %s", key)}
		seen[key] = true
		switch key {
		case "--dry-run": options.dry_run = true
		case "--project", "--output", "--target", "--rune-root", "--odin", "--glibc-max", "--windows-runtime-directory", "--windows-runtime-license":
			if i+1 == len(args) || args[i+1] == "" {return {}, fmt.aprintf("Missing value for %s", key)}
			i += 1
			switch key {
			case "--project": options.project = args[i]
			case "--output": options.output = args[i]
			case "--target": options.target = args[i]
			case "--rune-root": options.rune_root = args[i]
			case "--odin": options.compiler = args[i]
			case "--glibc-max": options.glibc_max = args[i]
			case "--windows-runtime-directory": options.windows_runtime_directory = args[i]
			case "--windows-runtime-license": options.windows_runtime_license = args[i]
			}
		case: return {}, fmt.aprintf("Unknown option: %s", key)
		}
	}
	return options, ""
}

run_main :: proc(args: []string) -> int {
	options, error := parse_options(args)
	if error != "" {fmt.eprintln(error); return 2}
	if options.help {
		fmt.println("Rune Publish - build portable Rune game packages.")
		fmt.println("Usage: rune_publish [--project GAME_DIRECTORY] [--output NEW_PACKAGE_DIRECTORY]")
		fmt.println("       [--target windows-amd64|linux-amd64] [--odin COMPILER] [--glibc-max 2.39]")
		fmt.println("       [--rune-root ENGINE_DIRECTORY]")
		fmt.println("       [--windows-runtime-directory OFFICIAL_VC_CRT_DIRECTORY] [--windows-runtime-license NOTICE]")
		fmt.println("       [--dry-run] Validate content and report pruning without building or writing a package.")
		fmt.println("Builds publish.json as a player package on the matching host OS, with an adjacent ZIP/tar.gz.")
		fmt.println("Use --rune-root or RUNE_ROOT with a standalone binary; tools/publish.bat|sh supplies it automatically.")
		return 0
	}
	if error = publish(options); error != "" {fmt.eprintln("Publishing failed: ", error); return 1}
	return 0
}

publish :: proc(options: Options) -> string {
	when ODIN_ARCH != .amd64 {return "Publishing currently supports AMD64 hosts only."}
	when ODIN_OS != .Windows && ODIN_OS != .Linux {return "Publishing currently supports Windows and Linux only."}
	if options.target != Current_Target {return "Build the requested target on its matching native OS; cross-compilation is not supported."}
	when ODIN_OS == .Linux {
		if options.windows_runtime_directory != "" || options.windows_runtime_license != "" {return "Windows runtime options are only available on Windows."}
		if _, valid := parse_glibc_version(options.glibc_max); !valid {return "Invalid --glibc-max; use a dotted numeric version such as 2.39."}
	}
	game_root, path_error := pathutil.absolute(options.project)
	if path_error != nil {return fmt.aprintf("Could not resolve project directory: %v", path_error)}
	rune_root := options.rune_root
	if rune_root == "" {rune_root = os.get_env("RUNE_ROOT", context.allocator)}
	if rune_root == "" {return "Pass --rune-root or use Rune's tools/publish launcher."}
	rune_root, path_error = pathutil.absolute(rune_root)
	if path_error != nil {return "Could not resolve Rune root."}
	if !os.exists(fmt.aprintf("%s/rune/core/core.odin", rune_root)) {return fmt.aprintf("Rune engine not found at %s", rune_root)}
	config_path := fmt.aprintf("%s/publish.json", game_root)
	config_data, config_read_error := os.read_entire_file(config_path, context.allocator)
	if config_read_error != nil {return fmt.aprintf("Could not read publish configuration %s: %v", config_path, config_read_error)}
	config, config_error := decode_config(config_data)
	if config_error != "" {return config_error}
	config_hash := hash_bytes(config_data)
	allowed := false
	for target in config.targets {if target == options.target {allowed = true}}
	if !allowed {return "The requested target is not enabled in publish.json."}
	binary_name := fmt.aprintf("%s%s", config.executable, Executable_Suffix)
	if strings.to_lower(binary_name) == "licenses" || strings.to_lower(binary_name) == "manifest.json" {return "Executable name collides with publisher metadata/notices."}
	for name, value in config.build.defines {
		if _, error := json_scalar_literal(value); error != "" {return fmt.aprintf("Invalid build.defines.%s: %s", name, error)}
	}
	files, content_error := collect_content(game_root, config, binary_name)
	if content_error != "" {return content_error}
	retained_files, pruning, pruning_error := prune_content(game_root, config, files)
	if pruning_error != "" {return pruning_error}
	files = retained_files
	if pruning.enabled {
		fmt.printf("Asset pruning: retained %d of %d files; removed %d files (%d bytes).\n", pruning.retained_files, pruning.candidate_files, pruning.pruned_files, pruning.pruned_bytes)
	}
	if options.dry_run {
		if error := validate_content_inventory(game_root, files); error != "" {return error}
		fmt.println("Dry run: content dependency checks passed; no package was written.")
		return ""
	}
	output := options.output
	if output == "" {output = fmt.aprintf("%s/build/publish/%s-%s-%s", game_root, config.id, config.version, options.target)}
	output, path_error = pathutil.absolute(output)
	if path_error != nil {return "Could not resolve output directory."}
	output, _ = filepath.clean(output)
	parent, leaf := filepath.split(output)
	if !content_portable_segment(leaf) {return "Output must name a new directory with a portable filename."}
	archive_output := fmt.aprintf("%s%s", output, Archive_Suffix)
	if path_is_present(output) || path_is_present(archive_output) {return fmt.aprintf("Output or archive already exists; choose a new directory: %s", output)}
	if error := check_output_parent(parent, game_root, config); error != "" {return error}
	compiler := options.compiler
	if strings.contains_any(compiler, "/\\") {
		compiler, path_error = pathutil.absolute(compiler)
		if path_error != nil {return "Could not resolve compiler path."}
	}
	version, compiler_error := run_capture({compiler, "version"}, game_root)
	if compiler_error != "" {return compiler_error}
	pins_data, pins_error := os.read_entire_file(fmt.aprintf("%s/toolchain.json", rune_root), context.allocator)
	if pins_error != nil {return "Could not read Rune toolchain.json."}
	pins: struct {odin_release, tested_odin_version: string}
	if json.unmarshal(pins_data, &pins) != nil || pins.odin_release == "" {return "Invalid Rune toolchain.json."}
	if !strings.contains(version, pins.odin_release) {return fmt.aprintf("Compiler does not match the release recorded in toolchain.json: %s", version)}
	odin_root, root_error := run_capture({compiler, "root"}, game_root)
	if root_error != "" {return root_error}
	odin_root = strings.trim_space(odin_root)
	notices, notice_error := collect_engine_notices(rune_root, odin_root)
	if notice_error != "" {return notice_error}
	append_files := make([dynamic]Publish_File)
	append(&append_files, ..files)
	append(&append_files, ..notices)
	files = append_files[:]
	if error := prepare_engine(rune_root); error != "" {return error}
	if error := os.make_directory_all(parent); error != nil && error != .Exist {return fmt.aprintf("Could not create output parent %s: %v", parent, error)}
	if error := content_check_source_path(parent); error != "" {return error}
	workspace, workspace_error := os.make_directory_temp(parent, ".rune-publish-*", context.allocator)
	if workspace_error != nil {return fmt.aprintf("Could not create staging directory: %v", workspace_error)}
	// Preserve unsuccessful work for inspection; never recursively delete a
	// configured source/output path or reuse an earlier executable.
	fmt.println("Staging: ", workspace)
	stage, _ := filepath.join({workspace, leaf})
	if error := os.make_directory(stage); error != nil {return fmt.aprintf("Could not create staging package: %v", error)}
	if error := copy_publish_files(files, stage); error != "" {return fmt.aprintf("%s\nStaging preserved at %s", error, workspace)}
	if error := validate_staged_project(stage); error != "" {return fmt.aprintf("%s\nStaging preserved at %s", error, workspace)}
	binary, _ := filepath.join({stage, binary_name})
	fmt.println("Building player: ", config.name)
	build_output, build_error := run_compiler(compiler_command(compiler, game_root, rune_root, binary, config), game_root)
	if build_output != "" {fmt.print(build_output)}
	if build_error != "" {return fmt.aprintf("%s\nStaging preserved at %s", build_error, workspace)}
	if !os.exists(binary) {return fmt.aprintf("The compiler did not produce the requested executable; staging preserved at %s", workspace)}
	when ODIN_OS == .Windows {
		if runtime_error := stage_windows_runtime(binary, options.windows_runtime_directory, options.windows_runtime_license, stage); runtime_error != "" {
			return fmt.aprintf("%s\nStaging preserved at %s", runtime_error, workspace)
		}
	}
	audit, audit_error := audit_binary(binary, options.target, options.glibc_max)
	if audit_error != "" {return fmt.aprintf("%s\nStaging preserved at %s", audit_error, workspace)}
	records, record_error := record_package(stage)
	if record_error != "" {return record_error}
	built, _ := time.time_to_rfc3339(time.now(), include_nanos = false)
	manifest := Manifest{
		format_version = 1, id = config.id, name = config.name, version = config.version,
		target = options.target, executable = binary_name, built_utc = built,
		compiler = strings.trim_space(version), config_sha256 = config_hash,
		rune_source = source_revision(rune_root), game_source = source_revision(game_root),
		profile = "player", configuration = config, native = audit, files = records,
		asset_pruning = pruning,
		native_sources = native_source_pins(rune_root),
	}
	manifest_data, marshal_error := json.marshal(manifest, {pretty = true, use_spaces = true})
	if marshal_error != nil {return fmt.aprintf("Could not encode manifest: %v", marshal_error)}
	if error := os.write_entire_file(fmt.aprintf("%s/manifest.json", stage), manifest_data); error != nil {return fmt.aprintf("Could not write manifest: %v", error)}
	archive := fmt.aprintf("%s/package%s", workspace, Archive_Suffix)
	fmt.println("Creating archive...")
	archive_error: string
	when ODIN_OS == .Windows {
		_, archive_error = run_capture({"tar.exe", "-a", "-cf", archive, "-C", workspace, "--", leaf}, workspace)
	} else {
		_, archive_error = run_capture({"tar", "-czf", archive, "-C", workspace, "--", leaf}, workspace)
	}
	if archive_error != "" {return fmt.aprintf("%s\nStaging preserved at %s", archive_error, workspace)}
	// All build, content, native-audit and archive checks precede publication.
	if path_is_present(output) || path_is_present(archive_output) {return fmt.aprintf("Output appeared during build; refusing to replace it. Staging preserved at %s", workspace)}
	if error := finalize_new_path(stage, output); error != "" {return fmt.aprintf("Could not finalize package %s: %s (staging %s)", output, error, workspace)}
	if error := finalize_new_path(archive, archive_output); error != "" {return fmt.aprintf("Package is at %s; could not finalize archive: %s (staging %s)", output, error, workspace)}
	_ = os.remove(workspace) // The now-empty directory only; never a recursive delete.
	fmt.println("Published: ", output)
	fmt.println("Archive:   ", archive_output)
	return ""
}

path_is_present :: proc(path: string) -> bool {
	_, error := os.lstat(path, context.allocator)
	return error == nil
}

native_source_pins :: proc(root: string) -> map[string]json.Value {
	result := make(map[string]json.Value)
	for relative in ([]string{"third_party/r3d-importer/sources.json", "third_party/r3d-shadows/sources.json", "third_party/rune-image/sources.json"}) {
		bytes, read_error := os.read_entire_file(fmt.aprintf("%s/%s", root, relative), context.allocator)
		if read_error != nil {continue}
		value, error := json.parse(bytes)
		if error == nil {result[relative] = value}
	}
	return result
}

check_output_parent :: proc(parent, game_root: string, config: Config) -> string {
	// Reject links in existing ancestors, including a symlink alias into content.
	current := parent
	for current != "" {
		info, error := os.lstat(current, context.allocator)
		if error == nil && info.type != .Directory {return fmt.aprintf("Output parent contains a link or non-directory: %s", current)}
		if error == nil {if link_error := content_reparse_error(current); link_error != "" {return link_error}}
		if error != nil && error != .Not_Exist {
			// Missing Windows paths use a platform error; os.exists is false for
			// these too. The nearest existing ancestor is still checked below.
			if os.exists(current) {return fmt.aprintf("Could not inspect output parent %s: %v", current, error)}
		}
		next, _ := filepath.split(strings.trim_right(current, "/\\"))
		if next == current || next == "" {break}
		current = next
	}
	for entries in ([2][]string{config.content, config.licenses}) {
		for entry in entries {
			source, _ := filepath.join({game_root, entry})
			info, error := os.stat(source, context.allocator)
			if error == nil && info.type == .Directory && publisher_path_is_within(source, parent) {
				return fmt.aprintf("Output staging would be inside included content: %s", entry)
			}
		}
	}
	return ""
}

json_scalar_literal :: proc(value: json.Value) -> (string, string) {
	if text, is_string := value.(json.String); is_string {
		// Odin strips enclosing single quotes to distinguish strings from
		// boolean/number-looking text. It does not parse JSON string escapes.
		return fmt.aprintf("'%s'", string(text)), ""
	}
	data, error := json.marshal(value)
	if error != nil {return "", "Could not encode compiler define."}
	return string(data), ""
}

hash_file :: proc(path: string) -> (string, string) {
	file, error := os.open(path)
	if error != nil {return "", fmt.aprintf("Could not hash %s: %v", path, error)}
	defer os.close(file)
	sha: sha2.Context_256
	sha2.init_256(&sha)
	buffer: [65536]u8
	for {
		count, read_error := os.read(file, buffer[:])
		if count > 0 {sha2.update(&sha, buffer[:count])}
		if read_error != nil && read_error != .EOF {return "", fmt.aprintf("Could not hash %s: %v", path, read_error)}
		if count == 0 || read_error == .EOF {break}
	}
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&sha, digest[:])
	encoded, _ := hex.encode(digest[:])
	return string(encoded), ""
}

hash_bytes :: proc(data: []u8) -> string {
	sha: sha2.Context_256
	sha2.init_256(&sha)
	sha2.update(&sha, data)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&sha, digest[:])
	encoded, _ := hex.encode(digest[:])
	return string(encoded)
}

record_package :: proc(root: string) -> ([]File_Record, string) {
	result := make([dynamic]File_Record)
	if error := record_directory(root, "", &result); error != "" {return nil, error}
	slice.sort_by(result[:], proc(a,b: File_Record)->bool{return a.path < b.path})
	return result[:], ""
}

// Do not use core:os Walker here: the pinned Windows implementation can leave
// its final FindFirstFile handle open, preventing package-directory renames.
// read_all_directory_by_path closes its iterator while its file is still valid.
record_directory :: proc(root, relative: string, records: ^[dynamic]File_Record) -> string {
	directory, _ := filepath.join({root, relative})
	entries, read_error := os.read_all_directory_by_path(directory, context.allocator)
	if read_error != nil {return fmt.aprintf("Could not record package directory %s: %v", directory, read_error)}
	for entry in entries {
		path, _ := filepath.join({directory, entry.name})
		name := entry.name
		if relative != "" {name = fmt.aprintf("%s/%s", relative, entry.name)}
		info, stat_error := os.lstat(path, context.allocator)
		if stat_error != nil {return fmt.aprintf("Could not record package file %s: %v", path, stat_error)}
		if info.type == .Directory {
			if error := record_directory(root, name, records); error != "" {return error}
		} else if info.type == .Regular {
			hash, error := hash_file(path)
			if error != "" {return error}
			append(records, File_Record{path = name, size = info.size, sha256 = hash, executable = .Execute_User in info.mode})
		} else {return fmt.aprintf("Unexpected non-file in package: %s", path)}
	}
	return ""
}

source_revision :: proc(root: string) -> Source_Revision {
	// A generated/untracked game can sit inside the engine checkout. Do not
	// attribute its source to the parent repository when it tracks no game files.
	tracked, tracked_error := run_capture({"git", "-C", root, "-c", "core.fsmonitor=", "ls-files", "--", "."}, root)
	if tracked_error != "" || strings.trim_space(tracked) == "" {return {commit = "unavailable", state = "unverified"}}
	commit, error := run_capture({"git", "-C", root, "rev-parse", "HEAD"}, root)
	if error != "" {return {commit = "unavailable", state = "unverified"}}
	status, status_error := run_capture({"git", "-C", root, "-c", "core.fsmonitor=", "status", "--porcelain", "--ignore-submodules=all"}, root)
	state := "unverified"
	if status_error == "" {state = "clean" if strings.trim_space(status) == "" else "working-tree"}
	return {commit = strings.trim_space(commit), state = state}
}
