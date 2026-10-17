package console

import "core:encoding/json"
import "core:mem"
import "core:testing"

@(test)
suggestion_arrows_wrap_without_editing_input_history_or_pending_results :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	execute(&dev, "help")
	register(&dev, "camera", "", completion_test_handler)
	register(&dev, "clock", "", completion_test_handler)
	insert_text(&dev, "c unfinished")
	set_input_caret(&dev, 1)
	dev.defer_reply = true
	dev.remote.result_len = 1
	dev.result_data = json.Integer(42)
	revision, sequence := dev.edit_revision, dev.log_sequence
	line_count, history_index := dev.line_count, dev.history_index
	for expected, index in ([7]int{1, 2, 3, 0, 3, 2, 1}) {
		reverse := index >= 4
		testing.expect(t, navigate_suggestions(&dev, reverse))
		matches := view_completion_matches(&dev)
		testing.expect(t, matches.selected == expected && len(matches.options) == 4)
		testing.expect(t, input_text(&dev) == "c unfinished" && dev.input_caret == 1 && dev.input_anchor == 1)
		testing.expect(t, dev.edit_revision == revision && dev.selection_target == .Input)
		testing.expect(t, dev.history_count == 1 && dev.history_index == history_index)
		testing.expect(t, dev.line_count == line_count && dev.log_sequence == sequence)
	}
	result, ok := dev.result_data.(json.Integer)
	testing.expect(t, ok && result == 42 && dev.defer_reply && dev.remote.result_len == 1)
}

@(test)
suggestion_enter_accepts_quoted_arguments_preserves_suffix_then_submits :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {
		t = t, arguments = {"entity1"}, argument_index = 1, prefix = "e",
		candidates = {"entity two", "entity one"},
	}
	dev := init()
	dev.is_open = true
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, "inspect entity1 eunfinished suffix🙂")
	set_input_caret(&dev, len("inspect entity1 e"))
	testing.expect(t, input_vertical(&dev, false))
	testing.expect(t, view_completion_matches(&dev).selected == 1)
	input_enter(&dev)
	testing.expect(t, input_text(&dev) == `inspect entity1 "entity two" suffix🙂`)
	testing.expect(t, dev.input_caret == len(`inspect entity1 "entity two"`) && dev.input_anchor == dev.input_caret)
	testing.expect(t, !probe.executed && dev.history_count == 0)
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
	input_enter(&dev)
	testing.expect(t, probe.executed && dev.history_count == 1 && dev.input_len == 0)
	testing.expect(t, string(dev.history[0].text[:dev.history[0].len]) == `inspect entity1 "entity two" suffix🙂`)
}

@(test)
suggestion_enter_handles_an_exact_token_and_dismisses_until_a_real_edit :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	insert_text(&dev, "clear")
	revision := dev.edit_revision
	testing.expect(t, accept_suggestion(&dev), "accepting an unchanged match still consumes Enter")
	testing.expect(t, input_text(&dev) == "clear" && dev.history_count == 0 && dev.edit_revision == revision)
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
	testing.expect(t, !edit(&dev, .End))
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
	testing.expect(t, edit(&dev, .Left))
	testing.expect(t, len(view_completion_matches(&dev).options) == 1)
	input_enter(&dev)
	testing.expect(t, input_text(&dev) == "clear" && dev.input_caret == 5 && dev.history_count == 0)
	input_enter(&dev)
	testing.expect(t, dev.input_len == 0 && dev.history_count == 1 && dev.line_count == 0)
}

@(test)
suggestion_tab_accepts_the_browsed_match_before_resuming_its_cycle :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	for reverse in ([2]bool{false, true}) {
		dev := init()
		dev.is_open = true
		register(&dev, "camera", "", completion_test_handler)
		register(&dev, "clock", "", completion_test_handler)
		insert_text(&dev, "c")
		testing.expect(t, navigate_suggestions(&dev))
		testing.expect(t, view_completion_matches(&dev).selected == 1 && input_text(&dev) == "c")
		testing.expect(t, complete(&dev, reverse))
		testing.expect(t, input_text(&dev) == "capture" && view_completion_matches(&dev).selected == 1)
		testing.expect(t, complete(&dev, reverse))
		testing.expect(t, input_text(&dev) == ("camera" if reverse else "clear"))
		testing.expect(t, accept_suggestion(&dev))
		testing.expect(t, len(view_completion_matches(&dev).options) == 0)
		complete(&dev)
		testing.expect(t, len(view_completion_matches(&dev).options) > 0, "Tab reopens an accepted menu")
	}
}

@(test)
suggestion_navigation_restarts_after_typing_and_rejects_selected_or_unfocused_input :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	register(&dev, "clock", "", completion_test_handler)
	insert_text(&dev, "c")
	testing.expect(t, navigate_suggestions(&dev))
	insert_text(&dev, "l")
	matches := view_completion_matches(&dev)
	testing.expect(t, matches.request.prefix == "cl" && matches.selected == 0 && len(matches.options) == 2)
	testing.expect(t, navigate_suggestions(&dev))
	testing.expect(t, accept_suggestion(&dev) && input_text(&dev) == "clock")
	set_input_caret(&dev, 1)
	dev.selection_target = .Output
	revision := dev.edit_revision
	testing.expect(t, !navigate_suggestions(&dev) && !accept_suggestion(&dev))
	testing.expect(t, dev.selection_target == .Output && dev.edit_revision == revision)
	dev.selection_target = .Input
	set_input_caret(&dev, 2, true)
	revision = dev.edit_revision
	testing.expect(t, !navigate_suggestions(&dev) && !accept_suggestion(&dev))
	testing.expect(t, dev.input_anchor == 1 && dev.input_caret == 2 && dev.edit_revision == revision)
	set_input_caret(&dev, 1)
	dev.is_open = false
	testing.expect(t, !navigate_suggestions(&dev) && !accept_suggestion(&dev))
	testing.expect(t, input_text(&dev) == "clock" && dev.history_count == 0)
}

@(test)
suggestion_vertical_routing_preserves_history_and_the_unsubmitted_draft :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	execute(&dev, "help")
	execute(&dev, "clear")
	testing.expect(t, input_vertical(&dev, true), "empty input uses history")
	testing.expect(t, input_text(&dev) == "clear" && dev.history_index == 1)
	testing.expect(t, input_vertical(&dev, false, history_only = true))
	testing.expect(t, dev.input_len == 0 && dev.history_index == -1)
	insert_text(&dev, "c unfinished")
	set_input_caret(&dev, 1)
	testing.expect(t, input_vertical(&dev, true, history_only = true))
	testing.expect(t, input_text(&dev) == "clear" && dev.history_index == 1)
	testing.expect(t, input_vertical(&dev, true, suggestions_visible = false))
	testing.expect(t, input_text(&dev) == "help" && dev.history_index == 0)
	testing.expect(t, input_vertical(&dev, false, history_only = true))
	testing.expect(t, input_vertical(&dev, false, history_only = true))
	testing.expect(t, input_text(&dev) == "c unfinished" && dev.input_caret == 1 && dev.history_index == -1)
	testing.expect(t, input_vertical(&dev, false))
	testing.expect(t, input_text(&dev) == "c unfinished" && dev.history_index == -1)
	edit(&dev, .Select_All)
	insert_text(&dev, "no_such_command")
	testing.expect(t, input_vertical(&dev, true), "no candidates uses history")
	testing.expect(t, input_text(&dev) == "clear" && dev.history_index == 1)
	testing.expect(t, input_vertical(&dev, false, history_only = true))
	testing.expect(t, input_text(&dev) == "no_such_command" && dev.history_index == -1)
}

@(test)
suggestion_enter_without_visible_rows_submits_and_pending_commands_keep_the_draft :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	insert_text(&dev, "c")
	dev.defer_reply = true
	dev.result_data = json.Integer(42)
	testing.expect(t, navigate_suggestions(&dev))
	input_enter(&dev)
	testing.expect(t, input_text(&dev) == "clear" && dev.history_count == 0)
	input_enter(&dev)
	testing.expect(t, input_text(&dev) == "clear" && dev.history_count == 0)
	result, ok := dev.result_data.(json.Integer)
	testing.expect(t, ok && result == 42 && dev.defer_reply)
	dev.defer_reply = false
	input_enter(&dev, suggestions_visible = false)
	testing.expect(t, dev.input_len == 0 && dev.history_count == 1)
	insert_text(&dev, "clear")
	input_enter(&dev, suggestions_visible = false)
	testing.expect(t, dev.input_len == 0 && dev.history_count == 2, "a hidden exact suggestion must not consume Enter")
}

@(test)
suggestion_navigation_owns_values_and_requeries_removed_live_candidates :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	borrowed := [3]u8{'c', 'a', 't'}
	probe := Argument_Completion_Probe {
		t = t, prefix = "c", candidates = {"cab", string(borrowed[:]), "cow"},
	}
	dev := init()
	dev.is_open = true
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, "inspect c")
	testing.expect(t, navigate_suggestions(&dev))
	testing.expect(t, view_completion_matches(&dev).selected == 1 && input_text(&dev) == "inspect c")
	mem.dynamic_arena_free_all(&scratch)
	copy(borrowed[:], "czz")
	probe.candidates = {"cab", "cow", "czz"}
	matches := view_completion_matches(&dev)
	testing.expect(t, matches.request.prefix == "c" && matches.selected == 0)
	probe.candidates = {}
	testing.expect(t, !accept_suggestion(&dev) && !navigate_suggestions(&dev))
	testing.expect(t, input_text(&dev) == "inspect c" && !probe.executed && dev.history_count == 0)
	probe.candidates = {"cherry"}
	testing.expect(t, accept_suggestion(&dev))
	testing.expect(t, input_text(&dev) == "inspect cherry" && !probe.executed)
}
