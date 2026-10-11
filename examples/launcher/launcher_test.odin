package main

import "core:os"
import "core:fmt"
import "core:path/filepath"
import "core:testing"

@(test)
returning_held_buttons_require_release_before_launch_or_exit :: proc(t: ^testing.T) {
	state: Pad_Action_State
	// InitWindow's empty input state must not arm actions before a real poll.
	launch, cancel := pad_actions_update(&state, false, false, false, false)
	testing.expect(t, !launch && !cancel)
	launch, cancel = pad_actions_update(&state, true, true, true, true)
	testing.expect(t, !launch && !cancel)
	launch, cancel = pad_actions_update(&state, true, true, false, false)
	testing.expect(t, !launch && !cancel)
	launch, cancel = pad_actions_update(&state, false, false, false, false)
	testing.expect(t, !launch && !cancel)
	launch, cancel = pad_actions_update(&state, true, true, true, true)
	testing.expect(t, launch && cancel)
	// Reopening or refocusing clears the armed state, even if the buttons
	// had previously been released during this launcher session.
	state = {}
	launch, cancel = pad_actions_update(&state, true, false, true, false)
	testing.expect(t, !launch && !cancel)
	launch, cancel = pad_actions_update(&state, false, false, false, false)
	testing.expect(t, !launch && !cancel)
	launch, cancel = pad_actions_update(&state, true, false, true, false)
	testing.expect(t, launch && !cancel)
}

@(test)
argument_parser_preserves_grouping_without_shell_expansion :: proc(t: ^testing.T) {
	args, ok := parse_example_args(`--console-dir="build/a b" 'two words' "" path\ with\ spaces C:\game\save $HOME;touch`)
	testing.expect(t, ok)
	defer free_example_args(args)
	expected := []string{"--console-dir=build/a b", "two words", "", "path with spaces", `C:\game\save`, "$HOME;touch"}
	testing.expect_value(t, len(args), len(expected))
	for arg, index in args {testing.expect_value(t, arg, expected[index])}
	for invalid in ([]string{`"unclosed`, `'unclosed`}) {
		bad, valid := parse_example_args(invalid)
		testing.expect(t, !valid)
		testing.expect_value(t, len(bad), 0)
	}
	empty, empty_ok := parse_example_args("  \t\n ")
	testing.expect(t, empty_ok)
	testing.expect_value(t, len(empty), 0)
	free_example_args(empty)
}

@(test)
command_modes_forward_arguments_and_build_only_collections :: proc(t: ^testing.T) {
	example := Example{path = "hello_3d", collections = {{name = "r3d", path = "third_party/r3d-odin"}}}
	args := []string{"--console-dir=build/console space", "--flag"}
	prebuilt := example_command(example, true, args)
	defer free_example_args(prebuilt)
	suffix :: ".exe" when ODIN_OS == .Windows else ""
	testing.expect_value(t, prebuilt[0], "./build/hello_3d" + suffix)
	testing.expect_value(t, len(prebuilt), 3)
	testing.expect_value(t, prebuilt[1], args[0])
	build := example_command(example, false, args)
	defer free_example_args(build)
	testing.expect_value(t, build[0], "odin")
	testing.expect_value(t, build[len(build) - 3], "--")
	testing.expect_value(t, build[len(build) - 2], args[0])
	testing.expect_value(t, build[len(build) - 4], "-collection:r3d=third_party/r3d-odin")
	testing.expect(t, prebuilt_mode("1", true))
	testing.expect(t, prebuilt_mode("", false))
	testing.expect(t, !prebuilt_mode("", true))
	testing.expect(t, !prebuilt_mode("0", true))
}

@(test)
path_detection_requires_a_regular_executable :: proc(t: ^testing.T) {
	directory, error := os.make_directory_temp("", "rune launcher ", context.allocator)
	testing.expect(t, error == nil)
	defer delete(directory)
	defer os.remove_all(directory)
	testing.expect(t, !odin_on_path(directory, context.allocator))
	filename := "odin.exe" when ODIN_OS == .Windows else "odin"
	binary, _ := filepath.join({directory, filename})
	defer delete(binary)
	testing.expect(t, os.make_directory(binary) == nil)
	testing.expect(t, !odin_on_path(directory, context.allocator))
	testing.expect(t, os.remove(binary) == nil)
	testing.expect(t, os.write_entire_file(binary, "test", {.Read_User, .Write_User, .Execute_User}) == nil)
	testing.expect(t, odin_on_path(directory, context.allocator))
	when ODIN_OS != .Windows {
		testing.expect(t, os.chmod(binary, {.Read_User, .Write_User}) == nil)
		testing.expect(t, !odin_on_path(directory, context.allocator))
	}
	when ODIN_OS == .Windows {
		testing.expect(t, odin_on_path(fmt.tprintf("\"%s\";missing-odin-dir", directory), context.allocator))
	}
}
