package console

import "core:fmt"
import "core:testing"
import "core:unicode/utf8"
import rl "vendor:raylib"

@(test)
suggestion_layout_reserves_output_and_keeps_the_active_match_visible :: proc(t: ^testing.T) {
	base := view_layout(1000, 720)
	for selected in 0 ..< 24 {
		layout := view_layout(1000, 720, 24, selected)
		testing.expect(t, layout.input == base.input, "showing suggestions must keep the command fixed")
		testing.expect(t, layout.suggestion_end - layout.suggestion_first == Suggestion_Max_Rows)
		testing.expect(t, layout.suggestion_first <= selected && selected < layout.suggestion_end)
		testing.expect(t, layout.suggestions.y + layout.suggestions.height < layout.input.y)
		testing.expect(t, layout.output.y + layout.output.height < layout.suggestions.y)
		testing.expect(t, layout.track.y == layout.output.y && layout.track.height == layout.output.height)
		testing.expect(t, layout.visible_rows < base.visible_rows && layout.visible_rows > 0)
	}
	layout := view_layout(1000, 720, 2, 1)
	testing.expect(t, layout.suggestion_first == 0 && layout.suggestion_end == 2)
	no_matches := view_layout(1000, 720)
	testing.expect(t, no_matches.suggestion_first == no_matches.suggestion_end)
	testing.expect(t, no_matches.suggestions.height == 0)
}

@(test)
suggestions_fit_the_panel_and_hide_in_tiny_windows :: proc(t: ^testing.T) {
	for size in ([8][2]f32{{1000, 720}, {420, 500}, {180, 320}, {180, 90}, {96, 54}, {36, 30}, {8, 8}, {1, 1}}) {
		layout := view_layout(size[0], size[1], 50, 49)
		testing.expect(t, layout.suggestion_first >= 0 && layout.suggestion_end <= 50)
		testing.expect(t, layout.input == view_layout(size[0], size[1]).input)
		if layout.suggestion_end > layout.suggestion_first {
			testing.expect(t, layout.suggestions.x >= layout.panel.x && layout.suggestions.y >= layout.panel.y)
			testing.expect(t, layout.suggestions.x + layout.suggestions.width <= layout.panel.x + layout.panel.width)
			testing.expect(t, layout.suggestions.y + layout.suggestions.height < layout.input.y)
			testing.expect(t, layout.visible_rows >= 1)
		} else {testing.expect(t, layout.suggestions.height == 0)}
		if size[1] <= 90 || size[0] < 120 {testing.expect(t, layout.suggestion_end == 0)}
	}
}

@(test)
suggestion_labels_truncate_without_splitting_utf8 :: proc(t: ^testing.T) {
	dev := init()
	for sample in ([3][2]string{{"abcdefghijkl", "ab..."}, {"éééééé", "éé..."}, {"🙂🙂🙂🙂🙂🙂", "🙂🙂..."}}) {
		text := sample[0]
		label := suggestion_label(&dev, text, 30, measure = view_test_measure)
		testing.expect(t, utf8.valid_string(label))
		testing.expect(t, view_test_measure(label, Font_Size) <= 30)
		testing.expect(t, label == sample[1])
	}
	testing.expect(t, suggestion_label(&dev, "short", 100, measure = view_test_measure) == "short")
	testing.expect(t, suggestion_label(&dev, "long label", 17, measure = view_test_measure) == "")
}

@(test)
suggestion_preview_obeys_editor_focus_and_selection :: proc(t: ^testing.T) {
	dev := init()
	dev.is_open = true
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
	insert_text(&dev, "c")
	matches := view_completion_matches(&dev)
	testing.expect(t, len(matches.options) == 2 && matches.selected == 0)
	complete(&dev)
	matches = view_completion_matches(&dev)
	testing.expect(t, matches.cycling && len(matches.options) == 2)
	dev.is_open = false
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
	dev.is_open = true
	dev.selection_target = .Output
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
	dev.selection_target = .Input
	set_input_caret(&dev, 0, true)
	testing.expect(t, len(view_completion_matches(&dev).options) == 0)
}

@(test)
clicking_suggestions_does_not_select_log_text :: proc(t: ^testing.T) {
	dev := init()
	clear_command(&dev, "")
	for index in 0 ..< 20 {info(&dev, fmt.tprintf("log %d", index))}
	insert_text(&dev, "c")
	layout := view_layout(1000, 720, 20, 15)
	view := build_view(&dev, layout.output.width, layout.visible_rows, view_test_measure)
	point := rl.Vector2{layout.suggestions.x + 20, layout.suggestions.y + 40}
	pointer_select(&dev, layout, view, point, true, true, false, 1, view_test_measure)
	testing.expect(t, dev.selection_target == .Input && !dev.renderer.dragging_text)
	testing.expect(t, input_text(&dev) == "c" && dev.input_caret == 1)
}
