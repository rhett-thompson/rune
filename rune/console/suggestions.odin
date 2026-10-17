package console

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

Suggestion_Max_Rows :: 5
Suggestion_Header_Height :: f32(24)
Suggestion_Padding :: f32(6)
Suggestion_Gap :: f32(8)

// Keep preview rules in one place so drawing and pointer layout agree. The
// underlying matches query stays available to headless callers and complete.
view_completion_matches :: proc(console: ^Console) -> Completion_Matches {
	if !console.is_open || console.selection_target != .Input {return {}}
	start, end := input_selection(console)
	if start != end {return {}}
	state := &console.completion
	if state.dismissed && state.edit_revision == console.edit_revision && state.command_count == console.command_count {return {}}
	matches := completion_matches(console)
	if console.input_len == 0 && !matches.cycling {return {}}
	return matches
}

// Keyboard actions must agree with what can actually be drawn, including a
// small window that has no space for the suggestion panel.
input_completion_matches :: proc(console: ^Console, width, height: f32) -> Completion_Matches {
	matches := view_completion_matches(console)
	layout := view_layout(width, height, len(matches.options), matches.selected)
	if layout.suggestion_end <= layout.suggestion_first {return {}}
	return matches
}

// Drawing and hit-testing share the visible row geometry, including the
// offset of a scrolling suggestion window.
suggestion_row :: proc(layout: View_Layout, index: int) -> rl.Rectangle {
	if index < layout.suggestion_first || index >= layout.suggestion_end {return {}}
	return {layout.suggestions.x + Suggestion_Padding,
		layout.suggestions.y + Suggestion_Header_Height + Suggestion_Padding +
			f32(index - layout.suggestion_first) * Row_Height,
		max(0, layout.suggestions.width - Suggestion_Padding * 2), Row_Height}
}

// Accept the clicked visible row using the same snapshot as layout. Popup
// header/padding and hidden rows do not change the editor or run a command.
click_suggestion :: proc(console: ^Console, layout: View_Layout, matches: Completion_Matches, pointer: rl.Vector2) -> bool {
	if !console.is_open || console.selection_target != .Input || !matches.valid {return false}
	state := &console.completion
	if state.dismissed && state.edit_revision == console.edit_revision && state.command_count == console.command_count {return false}
	start, end := input_selection(console)
	if start != end || layout.suggestions.height <= 0 ||
	   layout.suggestion_first < 0 || layout.suggestion_end <= layout.suggestion_first ||
	   layout.suggestion_end > len(matches.options) {return false}
	for index in layout.suggestion_first ..< layout.suggestion_end {
		row := suggestion_row(layout, index)
		// Half-open edges give a boundary between adjacent rows a single owner.
		if pointer.x < row.x || pointer.x >= row.x + row.width ||
		   pointer.y < row.y || pointer.y >= row.y + row.height {continue}
		clicked := matches
		clicked.selected = index
		return accept_suggestion_matches(console, clicked)
	}
	return false
}

// Labels are shortened at UTF-8 boundaries. ASCII dots also work with the
// embedded font, whose atlas deliberately contains only Latin codepoints.
suggestion_label :: proc(console: ^Console, text: string, width: f32,
	size: f32 = Font_Size, measure: Measure_Proc = nil) -> string {
	full := measure(text, size) if measure != nil else text_width(console, text, size)
	if full <= width {return text}
	dots := "..."
	dots_width := measure(dots, size) if measure != nil else text_width(console, dots, size)
	if dots_width > width {return ""}
	end := 0
	for end < len(text) {
		_, bytes := utf8.decode_rune(text[end:])
		next := end + max(1, bytes)
		pixels := measure(text[:next], size) if measure != nil else text_width(console, text[:next], size)
		if pixels + dots_width > width {break}
		end = next
	}
	return strings.concatenate({text[:end], dots}, context.temp_allocator)
}

draw_suggestions :: proc(console: ^Console, layout: View_Layout, matches: Completion_Matches) {
	if layout.suggestion_end <= layout.suggestion_first || layout.suggestions.height <= 0 {return}
	popup := layout.suggestions
	rl.DrawRectangleRounded(popup, 0.08, 6, {26, 38, 54, 255})
	rl.DrawRectangleRoundedLinesEx(popup, 0.08, 6, 1, {62, 107, 111, 255})
	clip(popup)
	count := fmt.tprintf("%d-%d / %d", layout.suggestion_first + 1, layout.suggestion_end, len(matches.options))
	count_width := text_width(console, count, 12)
	view_text(console, count, {popup.x + popup.width - 12 - count_width, popup.y + 8}, 12, Muted_Color)
	if popup.width >= 220 {
		view_text(console, "Suggestions", {popup.x + 12, popup.y + 8}, 12, Muted_Color)
	}
	for index in layout.suggestion_first ..< layout.suggestion_end {
		row := suggestion_row(layout, index)
		selected := index == matches.selected
		if selected {
			rl.DrawRectangleRounded(row, 0.16, 4, Selection_Color)
			rl.DrawRectangleV({row.x + 3, row.y + 5}, {2, Row_Height - 10}, Accent_Color)
		}
		label := suggestion_label(console, matches.options[index].text, row.width - 22)
		view_text(console, label, {row.x + 12, row.y + 3}, Font_Size, Accent_Color if selected else Text_Color)
	}
	rl.EndScissorMode()
}
