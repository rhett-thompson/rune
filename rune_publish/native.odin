package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// This is a direct-import audit. Graphics/audio drivers loaded by the operating
// system at runtime are outside its scope; do not execute untrusted games or ldd.
Native_Audit :: struct {
	target:        string,
	format:        string,
	architecture:  string,
	interpreter:   string,
	needed:        []string,
	search_paths:  []string,
	bundled:       []string,
	version_requirements: []string,
	glibc_max:     string,
	glibc_ceiling: string,
}

native_range :: proc(data: []u8, start, count: u64) -> bool {
	return start <= u64(len(data)) && count <= u64(len(data))-start
}

native_u16 :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset+1])<<8
}

native_u32 :: proc(data: []u8, offset: int) -> u32 {
	return u32(native_u16(data, offset)) | u32(native_u16(data, offset+2))<<16
}

native_u64 :: proc(data: []u8, offset: int) -> u64 {
	return u64(native_u32(data, offset)) | u64(native_u32(data, offset+4))<<32
}

PE_Section :: struct {rva, raw_size, raw_offset: u32}

pe_rva_offset :: proc(data: []u8, sections: []PE_Section, headers: u32, rva, size: u64) -> (int, bool) {
	if rva < u64(headers) && size <= u64(headers)-rva && native_range(data, rva, size) {
		return int(rva), true
	}
	for section in sections {
		if rva >= u64(section.rva) {
			delta := rva-u64(section.rva)
			if delta <= u64(section.raw_size) && size <= u64(section.raw_size)-delta {
				offset := u64(section.raw_offset)+delta
				if native_range(data, offset, size) {return int(offset), true}
			}
		}
	}
	return 0, false
}

pe_import_name :: proc(data: []u8, sections: []PE_Section, headers, rva: u32) -> (string, bool) {
	if rva == 0 {return "", false}
	// DLL names are short ASCII basenames. Reject malformed/unbounded strings.
	bytes: [dynamic]u8
	for index in 0..<512 {
		offset, ok := pe_rva_offset(data, sections, headers, u64(rva)+u64(index), 1)
		if !ok {return "", false}
		value := data[offset]
		if value == 0 {return strings.clone(string(bytes[:])), len(bytes)>0}
		if value < 32 || value > 126 || value == '/' || value == '\\' || value == ':' {return "", false}
		append(&bytes, value)
	}
	return "", false
}

native_append_unique :: proc(values: ^[dynamic]string, name: string) {
	for value in values {if strings.equal_fold(value, name) {return}}
	append(values, name)
}

parse_pe_imports :: proc(data: []u8, application := true) -> ([]string, string) {
	if !native_range(data, 0, 64) || data[0] != 'M' || data[1] != 'Z' {return nil, "not a PE executable (missing DOS header)"}
	pe := u64(native_u32(data, 60))
	if !native_range(data, pe, 24) {return nil, "truncated PE header"}
	base := int(pe)
	if string(data[base:base+4]) != "PE\x00\x00" {return nil, "invalid PE signature"}
	if native_u16(data, base+4) != 0x8664 {return nil, "Windows package requires an AMD64 executable"}
	characteristics := native_u16(data, base+22)
	if characteristics&0x0002 == 0 || (application && characteristics&0x2000 != 0) || (!application && characteristics&0x2000 == 0) {
		return nil, "PE image is not the expected executable application or DLL"
	}
	section_count := int(native_u16(data, base+6))
	optional_size := int(native_u16(data, base+20))
	optional := base+24
	if section_count < 1 || section_count > 96 || optional_size < 112 || !native_range(data, u64(optional), u64(optional_size)+u64(section_count)*40) {
		return nil, "invalid or truncated PE optional header/sections"
	}
	if native_u16(data, optional) != 0x20b {return nil, "Windows package requires PE32+ (64 bit)"}
	if application && native_u16(data, optional+68) != 2 {
		return nil, "Windows player requires the Windows GUI subsystem; publish with -subsystem:windows to avoid a console window"
	}
	headers := native_u32(data, optional+60)
	section_start := optional+optional_size
	sections := make([]PE_Section, section_count)
	for &section, index in sections {
		at := section_start+index*40
		section = {native_u32(data, at+12), native_u32(data, at+16), native_u32(data, at+20)}
		if !native_range(data, u64(section.raw_offset), u64(section.raw_size)) {return nil, "PE section extends beyond file"}
	}
	directory_count := native_u32(data, optional+108)
	if directory_count > u32((optional_size-112)/8) {return nil, "truncated PE data directories"}
	names: [dynamic]string
	for directory in ([2]int{1, 13}) {
		if u32(directory) >= directory_count {continue}
		entry := optional+112+directory*8
		rva, size := native_u32(data, entry), native_u32(data, entry+4)
		if rva == 0 && size == 0 {continue}
		stride := 20 if directory == 1 else 32
		if rva == 0 || size < u32(stride) || size > 16*1024*1024 {return nil, "invalid PE import directory size"}
		terminated := false
		for cursor := u64(0); cursor+u64(stride) <= u64(size); cursor += u64(stride) {
			at, ok := pe_rva_offset(data, sections, headers, u64(rva)+cursor, u64(stride))
			if !ok {return nil, "PE import descriptor has no file-backed data"}
			zero := true
			for value in data[at:at+stride] {if value != 0 {zero = false; break}}
			if zero {terminated = true; break}
			name_rva := native_u32(data, at+12)
			if directory == 13 {
				// PE32+ delay imports use RVAs. Legacy VA descriptors cannot
				// represent ordinary 64-bit image addresses and are refused.
				if native_u32(data, at) != 1 {return nil, "unsupported PE delay import attributes (expected RVAs)"}
				name_rva = native_u32(data, at+4)
			}
			name, valid := pe_import_name(data, sections, headers, name_rva)
			if !valid {return nil, "invalid PE imported DLL name"}
			native_append_unique(&names, name)
		}
		if !terminated {return nil, "unterminated PE import directory"}
	}
	return names[:], ""
}

windows_system_library :: proc(name: string) -> bool {
	lower := strings.to_lower(name)
	if (strings.has_prefix(lower, "api-ms-win-") || strings.has_prefix(lower, "ext-ms-win-")) && strings.has_suffix(lower, ".dll") {return true}
	// Windows components only. MSVC redistributables and game DLLs must not
	// silently depend on software installed on the publisher's workstation.
	for allowed in ([]string{
		"kernel32.dll", "kernelbase.dll", "ntdll.dll", "user32.dll", "gdi32.dll", "gdi32full.dll",
		"advapi32.dll", "shell32.dll", "shlwapi.dll", "ole32.dll", "oleaut32.dll", "combase.dll",
		"comdlg32.dll", "comctl32.dll", "uuid.dll", "ws2_32.dll", "mswsock.dll", "iphlpapi.dll",
		"winmm.dll", "imm32.dll", "version.dll", "setupapi.dll", "cfgmgr32.dll", "hid.dll",
		"opengl32.dll", "glu32.dll", "dwmapi.dll", "uxtheme.dll", "bcrypt.dll", "bcryptprimitives.dll",
		"crypt32.dll", "secur32.dll", "normaliz.dll", "powrprof.dll", "msvcrt.dll", "ucrtbase.dll",
		"winhttp.dll", "wininet.dll", "dnsapi.dll", "psapi.dll", "dbghelp.dll", "wintrust.dll",
		"xinput1_4.dll", "xinput9_1_0.dll", "dsound.dll", "dinput8.dll", "xaudio2_9.dll",
		"avrt.dll", "mmdevapi.dll", "propsys.dll", "d3d11.dll", "dxgi.dll", "dwrite.dll", "d2d1.dll",
	}) {if lower == allowed {return true}}
	return false
}

linux_system_library :: proc(name: string) -> bool {
	for allowed in ([]string{
		"libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1", "libresolv.so.2",
		"libgcc_s.so.1", "libstdc++.so.6", "libz.so.1", "ld-linux-x86-64.so.2", "libGL.so.1", "libGLX.so.0", "libGLdispatch.so.0",
		"libEGL.so.1", "libOpenGL.so.0", "libGLESv2.so.2", "libX11.so.6", "libX11-xcb.so.1",
		"libXrandr.so.2", "libXinerama.so.1", "libXcursor.so.1", "libXi.so.6", "libXext.so.6",
		"libXrender.so.1", "libXfixes.so.3", "libxcb.so.1", "libwayland-client.so.0",
		"libwayland-cursor.so.0", "libwayland-egl.so.1", "libxkbcommon.so.0", "libasound.so.2",
		"libpulse.so.0", "libpulse-simple.so.0", "libudev.so.1",
	}) {if name == allowed {return true}}
	return false
}

audit_needed_libraries :: proc(needed: []string, windows: bool) -> string {
	for name in needed {
		if strings.contains_any(name, "/\\:") {return fmt.aprintf("native dependency must be a library basename without a path: %q", name)}
		allowed := windows_system_library(name) if windows else linux_system_library(name)
		if !allowed {
			return fmt.aprintf("unbundled native dependency %q; publishing supports static engine/custom libraries and documented OS libraries only", name)
		}
	}
	return ""
}

windows_runtime_library :: proc(name: string) -> bool {
	for allowed in ([]string{
		"msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll", "msvcp140_codecvt_ids.dll",
		"vcruntime140.dll", "vcruntime140_1.dll", "vcruntime140_threads.dll", "concrt140.dll", "vccorlib140.dll",
	}) {if strings.equal_fold(name, allowed) {return true}}
	return false
}

windows_imports_file :: proc(path: string, application: bool) -> ([]string, string) {
	if failure := content_check_source_path(path); failure != "" {return nil, failure}
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return nil, fmt.aprintf("cannot read Windows native dependency: %s (%v)", path, read_error)}
	names, failure := parse_pe_imports(data, application)
	if failure != "" {return nil, fmt.aprintf("%s: %s", path, failure)}
	return names, ""
}

windows_crt_directory_number :: proc(name: string) -> (uint, bool) {
	if !strings.has_prefix(name, "Microsoft.VC") || !strings.has_suffix(name, ".CRT") {return 0, false}
	digits := name[len("Microsoft.VC"):len(name)-len(".CRT")]
	if len(digits) < 2 || len(digits) > 4 {return 0, false}
	for digit in digits {if digit < '0' || digit > '9' {return 0, false}}
	number, ok := strconv.parse_uint(digits, 10)
	return number, ok && number > 0
}

find_x64_windows_runtime :: proc(version_root: string) -> (string, string) {
	x64, _ := filepath.join({version_root, "x64"})
	if !os.exists(x64) {return "", ""}
	if failure := content_check_source_path(x64); failure != "" {return "", failure}
	info, stat_error := os.lstat(x64, context.allocator)
	if stat_error != nil || info.type != .Directory {return "", fmt.aprintf("Visual Studio x64 runtime path must be a directory: %s", x64)}
	entries, read_error := os.read_all_directory_by_path(x64, context.allocator)
	if read_error != nil {return "", fmt.aprintf("cannot inspect Visual Studio x64 runtime directory: %s (%v)", x64, read_error)}
	best, best_number := "", uint(0)
	for entry in entries {
		number, valid := windows_crt_directory_number(entry.name)
		if !valid || number <= best_number {continue}
		candidate, _ := filepath.join({x64, entry.name})
		if failure := content_check_source_path(candidate); failure != "" {return "", failure}
		info, stat_error := os.lstat(candidate, context.allocator)
		if stat_error != nil || info.type != .Directory {continue}
		best, best_number = candidate, number
	}
	return best, ""
}

// Accept the documented VCToolsRedistDir version root or a VS MSVC redist root.
// Enumerate only numeric versions and their ordinary x64 CRT child, excluding
// debug_nonredist, onecore, architecture aliases, junctions, and PATH searches.
find_windows_runtime :: proc(redist_root: string) -> (string, string) {
	if !os.exists(redist_root) {return "", ""}
	if failure := content_check_source_path(redist_root); failure != "" {return "", failure}
	root_info, root_error := os.lstat(redist_root, context.allocator)
	if root_error != nil || root_info.type != .Directory {return "", fmt.aprintf("Visual Studio runtime root must be a directory: %s", redist_root)}
	if _, direct := windows_crt_directory_number(filepath.base(strings.trim_right(redist_root, "/\\"))); direct {
		info, stat_error := os.lstat(redist_root, context.allocator)
		if stat_error == nil && info.type == .Directory {return redist_root, ""}
	}
	if directory, failure := find_x64_windows_runtime(redist_root); directory != "" || failure != "" {return directory, failure}
	entries, read_error := os.read_all_directory_by_path(redist_root, context.allocator)
	if read_error != nil {return "", fmt.aprintf("cannot inspect Visual Studio runtime versions: %s (%v)", redist_root, read_error)}
	// Select numerically, so 14.10 sorts after 14.9. Try older complete layouts
	// if the newest version has no ordinary x64 CRT directory.
	remaining := make([dynamic]string)
	for entry in entries {if _, valid := parse_glibc_version(entry.name); valid {append(&remaining, entry.name)}}
	for len(remaining) > 0 {
		best := 0
		for name, index in remaining {
			version, _ := parse_glibc_version(name)
			previous, _ := parse_glibc_version(remaining[best])
			if glibc_version_above(version, previous) {best = index}
		}
		version_root, _ := filepath.join({redist_root, remaining[best]})
		ordered_remove(&remaining, best)
		if directory, failure := find_x64_windows_runtime(version_root); directory != "" || failure != "" {return directory, failure}
	}
	return "", ""
}

windows_runtime_notice :: proc(directory: string) -> string {
	current := strings.trim_right(directory, "/\\")
	for current != "" {
		if strings.equal_fold(filepath.base(current), "VC") {
			installation, _ := filepath.split(current)
			notice, _ := filepath.join({installation, "Licenses", "1033", "ThirdPartyNotices.txt"})
			if os.is_file(notice) {return notice}
			return ""
		}
		parent, _ := filepath.split(current)
		parent = strings.trim_right(parent, "/\\")
		if parent == current {break}
		current = parent
	}
	return ""
}

discover_windows_runtime :: proc() -> (string, string, string) {
	if configured := os.get_env("VCToolsRedistDir", context.allocator); configured != "" {
		directory, failure := find_windows_runtime(configured)
		if failure != "" {return "", "", failure}
		if directory != "" {return directory, windows_runtime_notice(directory), ""}
	}
	program_files := os.get_env("ProgramFiles(x86)", context.allocator)
	if program_files == "" {return "", "", ""}
	vswhere, _ := filepath.join({program_files, "Microsoft Visual Studio", "Installer", "vswhere.exe"})
	if !os.is_file(vswhere) {return "", "", ""}
	if failure := content_check_source_path(vswhere); failure != "" {return "", "", failure}
	installation, failure := run_capture({vswhere, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"}, "")
	if failure != "" {return "", "", fmt.aprintf("cannot discover official Visual Studio CRT runtime; use --windows-runtime-directory: %s", failure)}
	installation = strings.trim_space(installation)
	if installation == "" {return "", "", ""}
	redist, _ := filepath.join({installation, "VC", "Redist", "MSVC"})
	directory, directory_error := find_windows_runtime(redist)
	if directory_error != "" {return "", "", directory_error}
	if directory == "" {return "", "", ""}
	return directory, windows_runtime_notice(directory), ""
}

// A supplied runtime directory is used only for this explicit list of official
// app-local VC runtime DLL names. Copy the dependency closure, never arbitrary
// game plugins and never anything from the publisher's process search path.
stage_windows_runtime :: proc(binary, runtime_directory, license_path, stage_root: string) -> string {
	initial, failure := windows_imports_file(binary, true)
	if failure != "" {return failure}
	needs_runtime := false
	for name in initial {
		if windows_system_library(name) {continue}
		if !windows_runtime_library(name) {return audit_needed_libraries([]string{name}, true)}
		needs_runtime = true
	}
	if !needs_runtime {return ""}
	runtime_directory, license_path := runtime_directory, license_path
	if runtime_directory == "" {
		detected, notice, discovery_error := discover_windows_runtime()
		if discovery_error != "" {return discovery_error}
		if detected == "" {return ""} // The following audit reports the missing DLL and override option.
		runtime_directory = detected
		if license_path == "" {license_path = notice}
		fmt.println("Using installed Visual Studio runtime: ", runtime_directory)
	}
	if failure := content_check_source_path(runtime_directory); failure != "" {return failure}
	info, stat_error := os.lstat(runtime_directory, context.allocator)
	if stat_error != nil || info.type != .Directory {return "--windows-runtime-directory must name a directory containing AMD64 VC runtime DLLs"}
	pending := make([dynamic]string)
	append(&pending, ..initial)
	visited := make(map[string]bool)
	files: [dynamic]Publish_File
	for cursor := 0; cursor < len(pending); cursor += 1 {
		name := strings.to_lower(pending[cursor])
		if windows_system_library(name) {continue}
		if !windows_runtime_library(name) {return audit_needed_libraries([]string{name}, true)}
		if visited[name] {continue}
		visited[name] = true
		source, _ := filepath.join({runtime_directory, name})
		destination, _ := filepath.join({stage_root, name})
		if os.exists(destination) {return fmt.aprintf("VC runtime destination already exists in package: %s", name)}
		imports, dependency_error := windows_imports_file(source, false)
		if dependency_error != "" {return dependency_error}
		append(&pending, ..imports)
		append(&files, Publish_File{source=source, destination=name})
	}
	if len(files) > 0 && license_path != "" {
		base := filepath.base(license_path)
		if !content_portable_segment(base) {return "VC runtime license filename is not portable"}
		append(&files, Publish_File{source=license_path, destination=fmt.aprintf("licenses/rune/microsoft-runtime/%s", base)})
	}
	return copy_publish_files(files[:], stage_root)
}

audit_windows_closure :: proc(binary: string, initial: []string) -> ([]string, string) {
	root, _ := filepath.split(binary)
	pending := make([dynamic]string)
	append(&pending, ..initial)
	bundled: [dynamic]string
	visited := make(map[string]bool)
	for cursor := 0; cursor < len(pending); cursor += 1 {
		name := strings.to_lower(pending[cursor])
		if windows_system_library(name) {continue}
		if !windows_runtime_library(name) {return nil, audit_needed_libraries([]string{name}, true)}
		if visited[name] {continue}
		visited[name] = true
		path, _ := filepath.join({root, name})
		if !os.is_file(path) {
			return nil, fmt.aprintf("missing app-local VC runtime dependency %q; pass --windows-runtime-directory with the official AMD64 Visual Studio CRT redist directory", name)
		}
		imports, failure := windows_imports_file(path, false)
		if failure != "" {return nil, failure}
		append(&pending, ..imports)
		append(&bundled, name)
	}
	return bundled[:], ""
}

parse_glibc_version :: proc(value: string) -> ([4]u32, bool) {
	parts := strings.split(value, ".")
	if len(parts) < 2 || len(parts) > 4 {return {}, false}
	version: [4]u32
	for part, index in parts {
		if len(part) == 0 {return {}, false}
		for digit in part {if digit < '0' || digit > '9' {return {}, false}}
		parsed, ok := strconv.parse_uint(part, 10)
		if !ok || parsed > 0xffff_ffff {return {}, false}
		version[index] = u32(parsed)
	}
	return version, true
}

glibc_version_above :: proc(left, right: [4]u32) -> bool {
	for index in 0..<4 {
		if left[index] > right[index] {return true}
		if left[index] < right[index] {return false}
	}
	return false
}

parse_glibc_requirements :: proc(output, ceiling: string) -> (string, string) {
	limit, valid := parse_glibc_version(ceiling)
	if !valid {return "", "invalid glibc ceiling (expected e.g. 2.39)"}
	if strings.contains(output, "GLIBC_PRIVATE") {return "", "binary requires unsupported GLIBC_PRIVATE symbols"}
	maximum: [4]u32
	max_text := ""
	for cursor := 0; cursor < len(output); {
		found := strings.index(output[cursor:], "GLIBC_")
		if found < 0 {break}
		start := cursor+found+6
		end := start
		for end < len(output) && ((output[end] >= '0' && output[end] <= '9') || output[end] == '.') {end += 1}
		if end == start {return "", "unsupported GLIBC version tag in binary"}
		if end < len(output) && ((output[end] >= 'a' && output[end] <= 'z') || (output[end] >= 'A' && output[end] <= 'Z') || output[end] == '_') {
			return "", "unsupported GLIBC version tag in binary"
		}
		text := output[start:end]
		version, ok := parse_glibc_version(text)
		if !ok {return "", "malformed GLIBC version requirement"}
		if glibc_version_above(version, limit) {return "", fmt.aprintf("binary requires GLIBC_%s above ceiling %s; rebuild using a compatible Linux SDK/sysroot", text, ceiling)}
		if max_text == "" || glibc_version_above(version, maximum) {maximum = version; max_text = text}
		cursor = end
	}
	return max_text, ""
}

parse_elf_dynamic :: proc(output: string) -> ([]string, []string, string) {
	names: [dynamic]string
	search_paths: [dynamic]string
	for line in strings.split_lines(output) {
		if strings.contains(line, "(RPATH)") || strings.contains(line, "(RUNPATH)") {
			left := strings.index(line, "[")
			right := strings.last_index(line, "]")
			if left < 0 || right < left+1 {return nil, nil, "malformed readelf RPATH/RUNPATH entry"}
			if right > left+1 {
				path := line[left+1:right]
				if path != "$ORIGIN" && path != "${ORIGIN}" && path != "$ORIGIN/" && path != "${ORIGIN}/" {
					return nil, nil, fmt.aprintf("ELF RPATH/RUNPATH is unsupported for publishing (%q); only an empty path or exact $ORIGIN/${ORIGIN} with an optional trailing slash is supported", path)
				}
				native_append_unique(&search_paths, strings.clone(path))
			}
			continue
		}
		if !strings.contains(line, "(NEEDED)") {continue}
		left := strings.index(line, "[")
		right := strings.last_index(line, "]")
		if left < 0 || right <= left+1 {return nil, nil, "malformed readelf NEEDED entry"}
		native_append_unique(&names, strings.clone(line[left+1:right]))
	}
	return names[:], search_paths[:], ""
}

parse_elf_needed :: proc(output: string) -> ([]string, string) {
	needed, _, failure := parse_elf_dynamic(output)
	return needed, failure
}

// Odin's ordinary Linux executable uses an origin RUNPATH. Since this publisher
// does not bundle Linux shared libraries, prevent content from shadowing an OS
// soname in that executable directory, including links and directory entries.
audit_linux_origin_collisions :: proc(binary: string, needed: []string) -> string {
	if failure := audit_needed_libraries(needed, false); failure != "" {return failure}
	root, _ := filepath.split(binary)
	for name in needed {
		path, _ := filepath.join({root, name})
		_, stat_error := os.lstat(path, context.allocator)
		if stat_error == nil {
			return fmt.aprintf("package entry %q would shadow a required Linux system library through $ORIGIN; app-local Linux shared libraries are unsupported", name)
		}
		if stat_error != .Not_Exist {return fmt.aprintf("cannot inspect package for Linux system library collision: %s (%v)", path, stat_error)}
	}
	return ""
}

parse_elf_version_names :: proc(output: string) -> []string {
	names: [dynamic]string
	for line in strings.split_lines(output) {
		marker := strings.index(line, "Name:")
		if marker < 0 {continue}
		fields := strings.fields(line[marker+5:])
		if len(fields) > 0 {native_append_unique(&names, strings.clone(fields[0]))}
	}
	return names[:]
}

parse_elf_interpreter :: proc(data: []u8) -> (string, string) {
	if !native_range(data, 0, 64) || string(data[:4]) != "\x7fELF" || data[4] != 2 || data[5] != 1 || data[6] != 1 ||
		(data[7] != 0 && data[7] != 3) || native_u16(data, 18) != 62 || native_u32(data, 20) != 1 ||
		(native_u16(data, 16) != 2 && native_u16(data, 16) != 3) {return "", "Linux package requires an ELF64 little-endian AMD64 executable"}
	programs := native_u64(data, 32)
	stride := u64(native_u16(data, 54))
	count := u64(native_u16(data, 56))
	if count == 0 || count == 0xffff || stride < 56 || !native_range(data, programs, count*stride) {return "", "invalid ELF program headers"}
	interpreter := ""
	for index in 0..<count {
		at := int(programs+index*stride)
		if native_u32(data, at) != 3 {continue} // PT_INTERP
		if interpreter != "" {return "", "duplicate ELF interpreter"}
		offset, size := native_u64(data, at+8), native_u64(data, at+32)
		if size < 2 || size > 4096 || !native_range(data, offset, size) || data[int(offset+size-1)] != 0 {return "", "invalid ELF interpreter string"}
		interpreter = strings.clone(string(data[int(offset):int(offset+size-1)]))
		if interpreter != "/lib64/ld-linux-x86-64.so.2" && interpreter != "/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" {
			return "", fmt.aprintf("unsupported ELF interpreter %q; use a standard GNU Linux AMD64 SDK/sysroot", interpreter)
		}
	}
	return interpreter, ""
}

audit_binary :: proc(binary_path, target, glibc_ceiling: string) -> (Native_Audit, string) {
	audit := Native_Audit{target = target, architecture = "amd64"}
	data, read_error := os.read_entire_file(binary_path, context.allocator)
	if read_error != nil {return {}, fmt.aprintf("cannot read executable for native audit: %s: %v", binary_path, read_error)}
	if target == "windows-amd64" {
		audit.format = "PE32+"
		imports, failure := parse_pe_imports(data)
		if failure != "" {return {}, failure}
		audit.needed = imports
		bundled, closure_error := audit_windows_closure(binary_path, imports)
		if closure_error != "" {return {}, closure_error}
		audit.bundled = bundled
		return audit, ""
	}
	if target != "linux-amd64" {return {}, "unsupported target for native audit"}
	interpreter, elf_error := parse_elf_interpreter(data)
	if elf_error != "" {return {}, elf_error}
	audit.interpreter = interpreter
	audit.format = "ELF64"
	audit.glibc_ceiling = glibc_ceiling
	dynamic_output, failure := run_capture([]string{"readelf", "--wide", "-d", binary_path}, "")
	if failure != "" {return {}, fmt.aprintf("native audit needs readelf: %s", failure)}
	needed, search_paths, parse_error := parse_elf_dynamic(dynamic_output)
	if parse_error != "" {return {}, parse_error}
	audit.needed = needed
	audit.search_paths = search_paths
	if failure = audit_needed_libraries(needed, false); failure != "" {return {}, failure}
	if failure = audit_linux_origin_collisions(binary_path, needed); failure != "" {return {}, failure}
	versions, version_error := run_capture([]string{"readelf", "--wide", "--version-info", binary_path}, "")
	if version_error != "" {return {}, fmt.aprintf("cannot inspect ELF symbol requirements: %s", version_error)}
	audit.version_requirements = parse_elf_version_names(versions)
	maximum, glibc_error := parse_glibc_requirements(versions, glibc_ceiling)
	if glibc_error != "" {return {}, glibc_error}
	audit.glibc_max = maximum
	return audit, ""
}
