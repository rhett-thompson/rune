package console

import "core:encoding/json"
import "core:mem"
import "core:testing"
import rl "vendor:raylib"

suggestion_click_point :: proc(layout: View_Layout, index: int) -> rl.Vector2 {
	row := suggestion_row(layout, index)
	return {row.x + row.width / 2, row.y + row.height / 2}
}

@(test)
suggestion_click_accepts_the_clicked_command_without_submitting_or_changing_pending_results :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	execute(&dev, "help")
	probe := Argument_Completion_Probe {t = t}
	dev.user_data = &probe
	register(&dev, "clock", "", argument_completion_handler)
	insert_text(&dev, "clunfinished suffix🙂")
	set_input_caret(&dev, 2)
	dev.defer_reply = true
	dev.remote.result_len = 1
	dev.result_data = json.Integer(42)
	line_count, sequence := dev.line_count, dev.log_sequence
	history_index := dev.history_index
	matches := view_completion_matches(&dev)
	layout := view_layout(1000, 720, len(matches.options), matches.selected)
	testing.expect(t, len(matches.options) == 2 && matches.selected == 0)
	testing.expect(t, click_suggestion(&dev, layout, matches, suggestion_click_point(layout, 1)))
	testing.expect(t, input_text(&dev) == "clock suffix🙂" && dev.input_caret == len("clock"))
	testing.expect(t, dev.input_anchor == dev.input_caret && dev.selection_target == .Input)
	testing.expect(t, !probe.executed && dev.history_count == 1 && dev.history_index == history_index)
	testing.expect(t, dev.line_count == line_count && dev.log_sequence == sequence)
	result, ok := dev.result_data.(json.Integer)
	testing.expect(t, ok && result == 42 && dev.defer_reply && dev.remote.result_len == 1)
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
}

@(test)
suggestion_click_quotes_arguments_preserves_the_suffix_and_leaves_enter_to_submit :: proc(t: ^testing.T) {
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
	matches := view_completion_matches(&dev)
	layout := view_layout(1000, 720, len(matches.options), matches.selected)
	testing.expect(t, click_suggestion(&dev, layout, matches, suggestion_click_point(layout, 1)))
	testing.expect(t, input_text(&dev) == `inspect entity1 "entity two" suffix🙂`)
	testing.expect(t, dev.input_caret == len(`inspect entity1 "entity two"`) && dev.input_anchor == dev.input_caret)
	testing.expect(t, !probe.executed && dev.history_count == 0)
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
	input_enter(&dev)
	testing.expect(t, probe.executed && dev.history_count == 1 && dev.input_len == 0)
	testing.expect(t, string(dev.history[0].text[:dev.history[0].len]) == `inspect entity1 "entity two" suffix🙂`)
}

@(test)
suggestion_click_uses_the_scrolled_visible_window_index :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {
		t = t, prefix = "e", candidates = {
			"entity 0", "entity 1", "entity 2", "entity 3", "entity 4",
			"entity 5", "entity 6", "entity 7", "entity 8", "entity 9",
		},
	}
	dev := init()
	dev.is_open = true
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, "inspect e")
	navigate_suggestions(&dev, true)
	matches := view_completion_matches(&dev)
	layout := view_layout(1000, 720, len(matches.options), matches.selected)
	testing.expect(t, matches.selected == 9 && layout.suggestion_first == 5 && layout.suggestion_end == 10)
	testing.expect(t, click_suggestion(&dev, layout, matches, suggestion_click_point(layout, layout.suggestion_first)))
	testing.expect(t, input_text(&dev) == `inspect "entity 5"` && !probe.executed)
}

@(test)
suggestion_click_ignores_popup_header_padding_hidden_rows_and_closed_console :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	insert_text(&dev, "c")
	matches := view_completion_matches(&dev)
	layout := view_layout(1000, 720, len(matches.options), matches.selected)
	row := suggestion_row(layout, layout.suggestion_first)
	last := suggestion_row(layout, layout.suggestion_end - 1)
	for point in ([7]rl.Vector2{
		{row.x + 10, layout.suggestions.y + 10},
		{row.x + 10, row.y - 1},
		{row.x - 1, row.y + 10},
		{row.x + row.width, row.y + 10},
		{row.x + 10, last.y + last.height},
		{row.x + 10, last.y + last.height + 1},
		{layout.suggestions.x + layout.suggestions.width + 1, row.y + 10},
	}) {
		testing.expect(t, !click_suggestion(&dev, layout, matches, point))
	}
	tiny := view_layout(1000, 90, len(matches.options), matches.selected)
	testing.expect(t, tiny.suggestion_end == 0)
	testing.expect(t, !click_suggestion(&dev, tiny, matches, suggestion_click_point(layout, 0)))
	testing.expect(t, !click_suggestion(&dev, layout, {}, suggestion_click_point(layout, 0)))
	dev.is_open = false
	testing.expect(t, !click_suggestion(&dev, layout, matches, suggestion_click_point(layout, 0)))
	testing.expect(t, input_text(&dev) == "c" && dev.input_caret == 1 && dev.history_count == 0)
	testing.expect(t, !dev.completion.dismissed)
}

@(test)
suggestion_click_accepts_an_exact_match_and_dismisses_the_popup_once :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	insert_text(&dev, "clear")
	matches := view_completion_matches(&dev)
	layout := view_layout(1000, 720, len(matches.options), matches.selected)
	point := suggestion_click_point(layout, 0)
	revision := dev.edit_revision
	testing.expect(t, click_suggestion(&dev, layout, matches, point))
	testing.expect(t, input_text(&dev) == "clear" && dev.edit_revision == revision && dev.history_count == 0)
	testing.expect(t, !dev.completion.active && !dev.completion.browsing && dev.completion.dismissed)
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
	testing.expect(t, !click_suggestion(&dev, layout, matches, point), "a stale row is no longer clickable after acceptance")
}

@(test)
suggestion_pointer_click_does_not_drag_the_logs_revealed_by_acceptance :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	dev.is_open = true
	clear_command(&dev, "")
	for index in 0 ..< 20 {info(&dev, "a log line to select")}
	insert_text(&dev, "c")
	matches := view_completion_matches(&dev)
	layout := view_layout(1000, 720, len(matches.options), matches.selected)
	view := build_view(&dev, layout.output.width, layout.visible_rows, view_test_measure)
	point := suggestion_click_point(layout, 1)
	dev.renderer.dragging_text = true
	dev.renderer.word_drag = true
	dev.renderer.drag_target = .Output
	dev.renderer.last_click_time = 0.9
	pointer_select(&dev, layout, view, point, true, true, false, 1, view_test_measure, &matches)
	testing.expect(t, input_text(&dev) == "clear" && dev.selection_target == .Input)
	testing.expect(t, !dev.renderer.dragging_text && !dev.renderer.word_drag && dev.renderer.last_click_time == 0)
	anchor, caret := dev.input_anchor, dev.input_caret
	selection := dev.output_selection
	no_matches := view_completion_matches(&dev)
	expanded := view_layout(1000, 720, len(no_matches.options), no_matches.selected)
	expanded_view := build_view(&dev, expanded.output.width, expanded.visible_rows, view_test_measure)
	testing.expect(t, rl.CheckCollisionPointRec(point, expanded.output), "the accepted row reveals output beneath the held pointer")
	pointer_select(&dev, expanded, expanded_view, point, false, true, false, 1.1, view_test_measure, &no_matches)
	testing.expect(t, dev.selection_target == .Input && dev.input_anchor == anchor && dev.input_caret == caret)
	testing.expect(t, dev.output_selection == selection && !dev.renderer.dragging_text)
	testing.expect(t, dev.history_count == 0 && input_text(&dev) == "clear")
}
