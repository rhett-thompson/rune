package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// All tool/config values are passed as argv, never interpreted as shell code.
run_capture :: proc(args: []string, cwd: string) -> (string, string) {
	state, output, errors, error := os.process_exec({command = args, working_dir = cwd}, context.allocator)
	if error != nil {return "", fmt.aprintf("Could not run %s: %v", args[0], error)}
	if !state.exited || state.exit_code != 0 {
		return string(output), fmt.aprintf("%s failed (exit %d):\n%s%s", args[0], state.exit_code, string(output), string(errors))
	}
	if len(errors) > 0 {fmt.eprint(string(errors))}
	return string(output), ""
}

// Cooperate with tools/odin.bat and tools/odin.sh. Children inherit the lock,
// so interrupting the publisher cannot release it while Odin is still running.
prepare_engine :: proc(root: string) -> string {
	when ODIN_OS == .Windows {
		_, error := run_capture({"cscript.exe", "//nologo", "//E:JScript", fmt.aprintf("%s/tools/prepare_r3d.bat", root)}, root)
		return error
	} else {
		_, error := run_capture({"sh", fmt.aprintf("%s/tools/prepare_r3d.sh", root)}, root)
		return error
	}
}

compiler_command :: proc(compiler, game_root, rune_root, binary: string, config: Config) -> []string {
	args := make([dynamic]string)
	append(&args, compiler, "build", game_root, "-o:speed", "-define:RUNE_PLAYER=true", "-define:RAYLIB_SHARED=false",
		fmt.aprintf("-collection:rune=%s/rune", rune_root), fmt.aprintf("-collection:r3d=%s/third_party/r3d-odin", rune_root),
		fmt.aprintf("-out:%s", binary))
	when ODIN_OS == .Windows {append(&args, "-linker:msvc", "-subsystem:windows")}
	for name, relative in config.build.collections {
		path, _ := filepath.join({game_root, relative})
		append(&args, fmt.aprintf("-collection:%s=%s", name, path))
	}
	for name, value in config.build.defines {
		// Typed define formatting follows Odin's single-quote string convention.
		literal, _ := json_scalar_literal(value)
		append(&args, fmt.aprintf("-define:%s=%s", name, literal))
	}
	if config.build.extra_linker_flags != "" {append(&args, fmt.aprintf("-extra-linker-flags:%s", config.build.extra_linker_flags))}
	return args[:]
}
