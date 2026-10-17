package console

import "core:encoding/json"
import "core:mem"
import "core:testing"

@(test)
suggestions_query_matches_tab_order_and_retains_the_original_prefix :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	register(&dev, "clock", "", completion_test_handler)
	register(&dev, "camera", "", completion_test_handler)
	register(&dev, "c bad", "", completion_test_handler)
	insert_text(&dev, "c")
	matches := completion_matches(&dev)
	testing.expect(t, matches.valid && matches.is_command && !matches.cycling)
	testing.expect(t, matches.start == 0 && matches.end == 1 && matches.request.prefix == "c")
	testing.expect(t, len(matches.options) == 4 && matches.selected == 0)
	for expected, index in ([4]string{"camera", "capture", "clear", "clock"}) {
		if index < len(matches.options) {
			testing.expect(t, matches.options[index].value == expected && matches.options[index].text == expected)
		}
	}
	for expected_index in 0 ..< 4 {
		testing.expect(t, complete(&dev))
		matches = completion_matches(&dev)
		testing.expect(t, matches.cycling && matches.selected == expected_index)
		testing.expect(t, matches.request.prefix == "c" && len(matches.options) == 4)
		if expected_index < len(matches.options) {
			testing.expect(t, input_text(&dev) == matches.options[expected_index].text)
		}
	}
	testing.expect(t, complete(&dev, true))
	matches = completion_matches(&dev)
	testing.expect(t, matches.selected == 2 && input_text(&dev) == "clear")
	testing.expect(t, complete(&dev))
	testing.expect(t, complete(&dev))
	matches = completion_matches(&dev)
	testing.expect(t, matches.selected == 0 && input_text(&dev) == "camera")
}

@(test)
suggestions_query_preserves_input_history_results_and_completion_state :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	execute(&dev, "clear")
	insert_text(&dev, "c")
	complete(&dev)
	dev.defer_reply = true
	dev.result_data = json.Integer(42)
	dev.remote.result_len = 1
	revision := dev.edit_revision
	sequence, line_count := dev.log_sequence, dev.line_count
	history_count, history_index := dev.history_count, dev.history_index
	before := dev.completion
	for _ in 0 ..< 2 {
		matches := completion_matches(&dev)
		testing.expect(t, len(matches.options) == 2 && matches.selected == 0 && matches.cycling)
	}
	testing.expect(t, input_text(&dev) == "capture" && dev.input_caret == 7 && dev.input_anchor == 7)
	testing.expect(t, dev.edit_revision == revision && dev.selection_target == .Input)
	testing.expect(t, dev.log_sequence == sequence && dev.line_count == line_count)
	testing.expect(t, dev.history_count == history_count && dev.history_index == history_index)
	testing.expect(t, dev.completion.active == before.active && dev.completion.prefix_len == before.prefix_len)
	testing.expect(t, dev.completion.current_len == before.current_len && dev.completion.edit_revision == before.edit_revision)
	testing.expect(t, string(dev.completion.prefix[:dev.completion.prefix_len]) == "c")
	testing.expect(t, string(dev.completion.current[:dev.completion.current_len]) == "capture")
	result, ok := dev.result_data.(json.Integer)
	testing.expect(t, ok && result == 42 && dev.defer_reply && dev.remote.result_len == 1)
}

@(test)
suggestions_arguments_show_the_same_quoted_token_that_tab_inserts :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {
		t = t, arguments = {"entity1"}, argument_index = 1, prefix = "e",
		candidates = {"entity two", "entity one", "entity two", "else\ninvalid", "other"},
	}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, "inspect entity1 eunfinished suffix")
	set_input_caret(&dev, len("inspect entity1 e"))
	matches := completion_matches(&dev)
	testing.expect(t, matches.valid && !matches.is_command && !matches.cycling && matches.selected == 0)
	testing.expect(t, matches.start == len("inspect entity1 ") && matches.end == len("inspect entity1 eunfinished"))
	testing.expect(t, matches.request.argument_index == 1 && len(matches.options) == 2)
	if len(matches.options) == 2 {
		testing.expect(t, matches.options[0].value == "entity one" && matches.options[0].text == `"entity one"`)
		testing.expect(t, matches.options[1].value == "entity two" && matches.options[1].text == `"entity two"`)
	}
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == `inspect entity1 "entity one" suffix`)
	matches = completion_matches(&dev)
	testing.expect(t, matches.cycling && matches.request.prefix == "e" && matches.selected == 0 && len(matches.options) == 2)
	testing.expect(t, complete(&dev))
	matches = completion_matches(&dev)
	testing.expect(t, matches.selected == 1 && input_text(&dev) == `inspect entity1 "entity two" suffix`)
	testing.expect(t, !probe.executed && probe.calls == 5)
}

@(test)
suggestions_refresh_live_sources_without_losing_the_cycle_prefix :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {t = t, prefix = "c", candidates = {"cat", "cow"}}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, "inspect c")
	complete(&dev)
	matches := completion_matches(&dev)
	testing.expect(t, matches.selected == 0 && len(matches.options) == 2)
	probe.candidates = {"camel", "copper", "copper"}
	matches = completion_matches(&dev)
	testing.expect(t, matches.cycling && matches.selected == 0 && len(matches.options) == 2)
	testing.expect(t, matches.request.prefix == "c" && input_text(&dev) == "inspect cat")
	if len(matches.options) == 2 {
		testing.expect(t, matches.options[0].value == "camel" && matches.options[1].value == "copper")
	}
	testing.expect(t, complete(&dev))
	matches = completion_matches(&dev)
	testing.expect(t, matches.selected == 1 && input_text(&dev) == "inspect copper")
	probe.candidates = {}
	matches = completion_matches(&dev)
	testing.expect(t, len(matches.options) == 0 && matches.selected == -1 && matches.cycling)
	probe.candidates = {"cherry"}
	matches = completion_matches(&dev)
	testing.expect(t, len(matches.options) == 1 && matches.selected == 0 && matches.request.prefix == "c")
	testing.expect(t, complete(&dev) && input_text(&dev) == "inspect cherry")
	testing.expect(t, !probe.executed)
}

@(test)
suggestions_refresh_the_prefix_after_edits_or_command_registration :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	insert_text(&dev, "c")
	complete(&dev)
	register(&dev, "carpet", "", completion_test_handler)
	matches := completion_matches(&dev)
	testing.expect(t, !matches.cycling && matches.request.prefix == "capture" && len(matches.options) == 1)
	testing.expect(t, matches.selected == 0 && input_text(&dev) == "capture")
	set_input_caret(&dev, 2)
	matches = completion_matches(&dev)
	testing.expect(t, !matches.cycling && matches.request.prefix == "ca" && len(matches.options) == 2)
	if len(matches.options) == 2 {
		testing.expect(t, matches.options[0].value == "capture" && matches.options[1].value == "carpet")
	}
	edit(&dev, .Select_All)
	insert_text(&dev, "he")
	matches = completion_matches(&dev)
	testing.expect(t, !matches.cycling && matches.request.prefix == "he" && len(matches.options) == 1)
	if len(matches.options) == 1 {testing.expect(t, matches.options[0].value == "help")}
}

@(test)
suggestions_hide_for_selections_and_output_focus_without_mutating_state :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {t = t, prefix = "c", candidates = {"cat", "cow"}}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, "inspect c")
	complete(&dev)
	set_input_caret(&dev, len("inspect "))
	set_input_caret(&dev, dev.input_len, true)
	revision := dev.edit_revision
	calls := probe.calls
	matches := completion_matches(&dev)
	testing.expect(t, len(matches.options) == 0 && matches.selected == -1)
	testing.expect(t, dev.input_anchor == len("inspect ") && dev.input_caret == dev.input_len)
	testing.expect(t, dev.completion.active && dev.edit_revision == revision && probe.calls == calls)
	set_input_caret(&dev, dev.input_len)
	dev.selection_target = .Output
	revision = dev.edit_revision
	matches = completion_matches(&dev)
	testing.expect(t, len(matches.options) == 0 && matches.selected == -1)
	testing.expect(t, dev.selection_target == .Output && dev.completion.active && dev.edit_revision == revision)
	testing.expect(t, probe.calls == calls && !probe.executed && input_text(&dev) == "inspect cat")
}

@(test)
suggestions_only_show_valid_candidates_that_fit_the_input :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {
		t = t, prefix = "q", candidates = {"q ", "qaa", "qz", "qz", "q\nline", "q\xc3"},
	}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	full: [Max_Input_Length]u8
	for &byte in full {byte = 'x'}
	copy(full[:], "inspect q ")
	insert_text(&dev, string(full[:Max_Input_Length - 1]))
	set_input_caret(&dev, len("inspect q"))
	matches := completion_matches(&dev)
	testing.expect(t, len(matches.options) == 1 && matches.selected == 0)
	if len(matches.options) == 1 {
		testing.expect(t, matches.options[0].value == "qz" && matches.options[0].text == "qz")
	}
	testing.expect(t, dev.input_len == Max_Input_Length - 1)
	testing.expect(t, complete(&dev) && dev.input_len == Max_Input_Length)
	matches = completion_matches(&dev)
	testing.expect(t, len(matches.options) == 1 && matches.selected == 0 && matches.cycling)
	testing.expect(t, !probe.executed)
}
