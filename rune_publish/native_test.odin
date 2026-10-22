package main

import "core:strings"
import "core:mem"
import "core:fmt"
import "core:os"
import "core:testing"

native_test_u16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset], data[offset+1] = u8(value), u8(value>>8)
}

native_test_u32 :: proc(data: []u8, offset: int, value: u32) {
	native_test_u16(data, offset, u16(value))
	native_test_u16(data, offset+2, u16(value>>16))
}

native_test_pe :: proc(normal, delayed: string) -> []u8 {
	data := make([]u8, 0x600)
	copy(data, "MZ")
	native_test_u32(data, 60, 0x80)
	copy(data[0x80:], "PE\x00\x00")
	native_test_u16(data, 0x84, 0x8664)
	native_test_u16(data, 0x86, 1)
	native_test_u16(data, 0x94, 240)
	native_test_u16(data, 0x96, 2)
	native_test_u16(data, 0x98, 0x20b)
	native_test_u32(data, 0x98+60, 0x200)
	native_test_u16(data, 0x98+68, 2)
	native_test_u32(data, 0x98+108, 16)
	section := 0x98+240
	native_test_u32(data, section+12, 0x1000)
	native_test_u32(data, section+16, 0x400)
	native_test_u32(data, section+20, 0x200)
	if normal != "" {
		native_test_u32(data, 0x98+120, 0x1000)
		native_test_u32(data, 0x98+124, 40)
		native_test_u32(data, 0x200+12, 0x1080)
		copy(data[0x280:], normal)
	}
	if delayed != "" {
		native_test_u32(data, 0x98+216, 0x1100)
		native_test_u32(data, 0x98+220, 64)
		native_test_u32(data, 0x300, 1)
		native_test_u32(data, 0x304, 0x1180)
		copy(data[0x380:], delayed)
	}
	return data
}

native_test_dll :: proc(normal, delayed: string) -> []u8 {
	data := native_test_pe(normal, delayed)
	native_test_u16(data, 0x96, 0x2002)
	return data
}

@(test)
native_pe_imports :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	data := native_test_pe("KERNEL32.dll", "opengl32.dll")
	names, failure := parse_pe_imports(data)
	testing.expect(t, failure == "", failure)
	testing.expect(t, len(names) == 2)
	if len(names) == 2 {
		testing.expect(t, names[0] == "KERNEL32.dll" && names[1] == "opengl32.dll")
	}
	testing.expect(t, audit_needed_libraries(names, true) == "")
	for name in ([]string{"VCRUNTIME140.dll", "MSVCP140.dll", "raylib.dll", "custom.dll", "xinput1_3.dll"}) {
		testing.expect(t, audit_needed_libraries([]string{name}, true) != "", name)
	}
	testing.expect(t, windows_system_library("API-MS-WIN-CRT-RUNTIME-L1-1-0.DLL"))
}

@(test)
native_pe_player_requires_gui_subsystem :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	data := native_test_pe("kernel32.dll", "")
	_, failure := parse_pe_imports(data)
	testing.expect(t, failure == "", failure)
	for subsystem in ([]u16{0, 1, 3}) {
		native_test_u16(data, 0x98+68, subsystem)
		_, failure = parse_pe_imports(data)
		testing.expect(t, strings.contains(failure, "Windows GUI subsystem"), failure)
	}
	// Dependency DLLs do not control whether launching the player opens a console.
	dll := native_test_dll("kernel32.dll", "")
	native_test_u16(dll, 0x98+68, 3)
	_, failure = parse_pe_imports(dll, false)
	testing.expect(t, failure == "", failure)
}

@(test)
native_pe_malformed :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	data := native_test_pe("kernel32.dll", "custom.dll")
	for size in ([]int{0, 2, 63, 128, 160, 400, len(data)-1}) {
		_, failure := parse_pe_imports(data[:size])
		testing.expect(t, failure != "", "truncated PE should fail")
	}
	native_test_u32(data, 0x304, 0xffff_ffff)
	_, failure := parse_pe_imports(data)
	testing.expect(t, failure != "", "invalid delay import RVA should fail")
	data = native_test_pe("kernel32.dll", "custom.dll")
	native_test_u32(data, 0x300, 0)
	_, failure = parse_pe_imports(data)
	testing.expect(t, failure != "", "legacy delay import VA should fail")
	data = native_test_pe("kernel32.dll", "")
	native_test_u32(data, 0x98+124, 20)
	_, failure = parse_pe_imports(data)
	testing.expect(t, failure != "", "missing import terminator should fail")
	data = native_test_pe("../custom.dll", "")
	_, failure = parse_pe_imports(data)
	testing.expect(t, failure != "", "DLL name with path should fail")
	data = native_test_pe("kernel32.dll", "")
	native_test_u16(data, 0x84, 0x14c)
	_, failure = parse_pe_imports(data)
	testing.expect(t, failure != "", "32 bit PE should fail")
}

@(test)
native_glibc_versions :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	maximum, failure := parse_glibc_requirements("Name: GLIBC_2.2.5 Flags: none\nName: GLIBC_2.9\nName: GLIBC_2.39", "2.39")
	testing.expect(t, failure == "" && maximum == "2.39", failure)
	for output in ([]string{"Name: GLIBC_2.40", "Name: GLIBC_PRIVATE", "Name: GLIBC_2..2", "Name: GLIBC_ABI_DT_RELR", "Name: GLIBC_2.39_custom"}) {
		_, failure = parse_glibc_requirements(output, "2.39")
		testing.expect(t, failure != "", output)
	}
	for ceiling in ([]string{"2", "2.x", "2..39", "2.39.0.0.1", "2.4294967296", "2.-1"}) {
		_, failure = parse_glibc_requirements("", ceiling)
		testing.expect(t, failure != "", ceiling)
	}
	_, failure = parse_glibc_requirements("Name: GLIBC_2.10", "2.9")
	testing.expect(t, failure != "", "compare versions numerically")
	_, failure = parse_glibc_requirements("Name: GLIBC_2.39.0", "2.39")
	testing.expect(t, failure == "", failure)
}

@(test)
native_linux_dependencies :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	names, failure := parse_elf_needed(" 0x00000001 (NEEDED) Shared library: [libc.so.6]\n 0x00000001 (NEEDED) Shared library: [libm.so.6]\n")
	testing.expect(t, failure == "" && len(names) == 2, failure)
	testing.expect(t, audit_needed_libraries(names, false) == "")
	for name in ([]string{"libraylib.so", "libr3d.so", "libcustom.so.1", "/home/build/libc.so.6", "../libc.so.6", "lib/libc.so.6", `lib\libc.so.6`}) {
		testing.expect(t, audit_needed_libraries([]string{name}, false) != "", name)
	}
	for name in ([]string{"api-ms-win-test/path.dll", `api-ms-win-test\path.dll`, "api-ms-win-test:stream.dll"}) {
		testing.expect(t, audit_needed_libraries([]string{name}, true) != "", name)
	}
	_, failure = parse_elf_needed("(NEEDED) Shared library: broken")
	testing.expect(t, failure != "")
	testing.expect(t, linux_system_library("libstdc++.so.6"))
	for output in ([]string{
		`0x000000000000000f (RPATH) Library rpath: [/home/build/lib]`,
		`0x000000000000001d (RUNPATH) Library runpath: [../lib]`,
		`0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN/lib]`,
		`0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN/..]`,
		`0x000000000000001d (RUNPATH) Library runpath: [${ORIGIN}/../lib]`,
		`0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN:$ORIGIN]`,
	}) {
		_, failure = parse_elf_needed(output)
		testing.expect(t, strings.contains(failure, "RPATH/RUNPATH is unsupported"), failure)
	}
	_, failure = parse_elf_needed(`(RPATH) Library rpath: malformed`)
	testing.expect(t, failure != "", "malformed runtime search path should fail")
	names, failure = parse_elf_needed("(RPATH) Library rpath: []\n(RUNPATH) Library runpath: []\n(NEEDED) Shared library: [libc.so.6]")
	testing.expect(t, failure == "" && len(names) == 1 && names[0] == "libc.so.6", failure)
	for origin in ([]string{"$ORIGIN", "${ORIGIN}", "$ORIGIN/", "${ORIGIN}/"}) {
		_, paths, origin_error := parse_elf_dynamic(fmt.aprintf("(RUNPATH) Library runpath: [%s]", origin))
		testing.expect(t, origin_error == "" && len(paths) == 1 && paths[0] == origin, origin_error)
	}
	versions := parse_elf_version_names("  Name: GLIBCXX_3.4.30 Flags: none Version: 4\n Name: CXXABI_1.3.13 Flags: none\n Name: GLIBC_2.34 Flags: none")
	testing.expect(t, len(versions) == 3 && versions[0] == "GLIBCXX_3.4.30" && versions[1] == "CXXABI_1.3.13")
}

@(test)
native_linux_origin_collisions :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	binary := fmt.aprintf("%s/game", root)
	testing.expect(t, audit_linux_origin_collisions(binary, {"libc.so.6", "libm.so.6"}) == "")
	content_test_write(t, root, "libc.so.6", "would shadow OS libc")
	failure := audit_linux_origin_collisions(binary, {"libc.so.6"})
	testing.expect(t, strings.contains(failure, "shadow a required Linux system library"), failure)
	testing.expect(t, os.remove(fmt.aprintf("%s/libc.so.6", root)) == nil)
	testing.expect(t, os.make_directory(fmt.aprintf("%s/libm.so.6", root)) == nil)
	failure = audit_linux_origin_collisions(binary, {"libm.so.6"})
	testing.expect(t, failure != "", "soname directory collision should fail")
	when ODIN_OS == .Linux {
		link := fmt.aprintf("%s/libc.so.6", root)
		testing.expect(t, os.symlink(fmt.aprintf("%s/nonexistent", root), link) == nil)
		failure = audit_linux_origin_collisions(binary, {"libc.so.6"})
		testing.expect(t, failure != "", "broken soname link should fail")
		testing.expect(t, os.remove(link) == nil)
	}
}

native_test_elf :: proc(loader: string) -> []u8 {
	data := make([]u8, 256)
	copy(data, "\x7fELF")
	data[4], data[5], data[6] = 2, 1, 1
	native_test_u16(data, 16, 2)
	native_test_u16(data, 18, 62)
	native_test_u32(data, 20, 1)
	native_test_u32(data, 32, 64)
	native_test_u16(data, 54, 56)
	native_test_u16(data, 56, 1)
	if loader != "" {
		native_test_u32(data, 64, 3)
		native_test_u32(data, 72, 128)
		native_test_u32(data, 96, u32(len(loader)+1))
		copy(data[128:], loader)
	}
	return data
}

@(test)
native_elf_headers :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for loader in ([]string{"", "/lib64/ld-linux-x86-64.so.2", "/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"}) {
		parsed, failure := parse_elf_interpreter(native_test_elf(loader))
		testing.expect(t, failure == "" && parsed == loader, failure)
	}
	data := native_test_elf("/home/build/ld-custom.so")
	_, failure := parse_elf_interpreter(data)
	testing.expect(t, strings.contains(failure, "unsupported ELF interpreter"))
	data = native_test_elf("")
	native_test_u16(data, 18, 183)
	_, failure = parse_elf_interpreter(data)
	testing.expect(t, failure != "", "ARM64 ELF should fail")
	data = native_test_elf("")
	native_test_u32(data, 32, 0xffff_ffff)
	_, failure = parse_elf_interpreter(data)
	testing.expect(t, failure != "", "out of range program headers should fail")
}

@(test)
native_windows_runtime_closure :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	stage := fmt.aprintf("%s/stage", root)
	runtime := fmt.aprintf("%s/runtime", root)
	binary := fmt.aprintf("%s/game.exe", stage)
	content_test_write(t, stage, "game.exe", string(native_test_pe("MSVCP140.dll", "")))
	content_test_write(t, runtime, "msvcp140.dll", string(native_test_dll("VCRUNTIME140.dll", "kernel32.dll")))
	_, failure := audit_binary(binary, "windows-amd64", "2.39")
	testing.expect(t, strings.contains(failure, "--windows-runtime-directory"), failure)
	failure = stage_windows_runtime(binary, runtime, "", stage)
	testing.expect(t, failure != "", "missing transitive runtime DLL should fail")
	testing.expect(t, !os.exists(fmt.aprintf("%s/msvcp140.dll", stage)), "validate all runtime inputs before copying")
	content_test_write(t, runtime, "vcruntime140.dll", string(native_test_dll("api-ms-win-crt-runtime-l1-1-0.dll", "")))
	content_test_write(t, root, "notice.txt", "Supplied runtime notice")
	failure = stage_windows_runtime(binary, runtime, fmt.aprintf("%s/notice.txt", root), stage)
	testing.expect(t, failure == "", failure)
	report, audit_error := audit_binary(binary, "windows-amd64", "2.39")
	testing.expect(t, audit_error == "" && len(report.bundled) == 2, audit_error)
	testing.expect(t, os.is_file(fmt.aprintf("%s/licenses/rune/microsoft-runtime/notice.txt", stage)))
	testing.expect(t, stage_windows_runtime(binary, runtime, "", stage) != "", "never overwrite package files")
	content_test_write(t, stage, "vcruntime140.dll", string(native_test_dll("custom.dll", "")))
	_, failure = audit_binary(binary, "windows-amd64", "2.39")
	testing.expect(t, strings.contains(failure, "custom.dll"), failure)
	stage2 := fmt.aprintf("%s/stage2", root)
	binary2 := fmt.aprintf("%s/game.exe", stage2)
	content_test_write(t, stage2, "game.exe", string(native_test_pe("MSVCP140.dll", "")))
	wrong_arch := native_test_dll("kernel32.dll", "")
	native_test_u16(wrong_arch, 0x84, 0x14c)
	content_test_write(t, runtime, "msvcp140.dll", string(wrong_arch))
	failure = stage_windows_runtime(binary2, runtime, "", stage2)
	testing.expect(t, strings.contains(failure, "AMD64"), failure)
}

@(test)
native_windows_runtime_discovery_selection :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	redist := fmt.aprintf("%s/VC/Redist/MSVC", root)
	content_test_write(t, redist, "14.9.100/x64/Microsoft.VC143.CRT/runtime.txt", "old")
	content_test_write(t, redist, "14.10.100/x64/Microsoft.VC145.CRT/runtime.txt", "new")
	content_test_write(t, redist, "14.10.100/x64/Microsoft.VC143.CRT/runtime.txt", "older CRT family")
	content_test_write(t, redist, "14.20.100/onecore/x64/Microsoft.VC999.CRT/runtime.txt", "exclude onecore")
	content_test_write(t, redist, "14.21.100/debug_nonredist/x64/Microsoft.VC999.CRT/runtime.txt", "exclude debug")
	content_test_write(t, redist, "14.22.100/x86/Microsoft.VC999.CRT/runtime.txt", "exclude x86")
	content_test_write(t, redist, "v999/x64/Microsoft.VC999.CRT/runtime.txt", "exclude aliases")
	content_test_write(t, redist, "14.23.100/x64/Microsoft.VCbad.CRT/runtime.txt", "exclude invalid CRT name")
	content_test_write(t, root, "Licenses/1033/ThirdPartyNotices.txt", "Installed VS notices")
	selected, failure := find_windows_runtime(redist)
	testing.expect(t, failure == "" && strings.has_suffix(content_slashes(selected), "/14.10.100/x64/Microsoft.VC145.CRT"), failure)
	version_root := fmt.aprintf("%s/14.10.100", redist)
	configured, configured_error := find_windows_runtime(version_root)
	testing.expect(t, configured_error == "" && configured == selected, configured_error)
	direct, direct_error := find_windows_runtime(selected)
	testing.expect(t, direct_error == "" && direct == selected, direct_error)
	testing.expect(t, strings.has_suffix(content_slashes(windows_runtime_notice(selected)), "/Licenses/1033/ThirdPartyNotices.txt"))
	missing, missing_error := find_windows_runtime(fmt.aprintf("%s/missing", root))
	testing.expect(t, missing == "" && missing_error == "")
	content_test_write(t, root, "invalid/x64", "not a directory")
	_, invalid_error := find_windows_runtime(fmt.aprintf("%s/invalid", root))
	testing.expect(t, invalid_error != "", "runtime x64 must be a directory")
	when ODIN_OS == .Linux {
		linked_version := fmt.aprintf("%s/14.99.100", redist)
		testing.expect(t, os.make_directory(linked_version) == nil)
		link := fmt.aprintf("%s/x64", linked_version)
		testing.expect(t, os.symlink(fmt.aprintf("%s/x64", version_root), link) == nil)
		_, unsafe_error := find_windows_runtime(redist)
		testing.expect(t, unsafe_error != "", "automatic runtime discovery must reject linked ancestors")
		testing.expect(t, os.remove(link) == nil)
	}
}
