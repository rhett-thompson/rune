package console

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

selection_view_measure :: proc(text: string, size: f32) -> f32 {
	width: f32
	for _ in text {width += 6}
	return width
}

@(test)
output_selection_copies_logical_text_across_wrapped_rows :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	info(&dev, "alpha beta gamma")
	first := dev.log_sequence
	info(&dev, "delta epsilon")
	last := dev.log_sequence
	view := build_view(&dev, 30, 20, selection_view_measure)
	testing.expect(t, len(view.rows) > dev.line_count)
	select_output(&dev, {first, 6}, {last, 5})
	testing.expect(t, selected_text(&dev) == "beta gamma\ndelta")
	select_output(&dev, {last, 5}, {first, 6})
	testing.expect(t, selected_text(&dev) == "beta gamma\ndelta", "reversed drag selects the same logical range")
	select_all(&dev)
	testing.expect(t, selected_text(&dev) == "alpha beta gamma\ndelta epsilon")
	// Result chunk boundaries do not become newlines in copied JSON.
	dev.lines[(dev.line_start + 1) % Max_Log_Lines].continues_previous = true
	testing.expect(t, selected_text(&dev) == "alpha beta gammadelta epsilon")
}

@(test)
semantic_output_word_selection_keeps_entity_id_punctuation :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	log_result(&dev, `{"id":"enemy.alpha-1","name":"Alpha"}`)
	line := &dev.lines[dev.line_start]
	testing.expect(t, line.span_count == 1)
	select_output_word(&dev, {line.sequence, int(line.spans[0].start) + 5})
	testing.expect(t, selected_text(&dev) == "enemy.alpha-1")
	clear_command(&dev, "")
	log_result(&dev, `{"id":"enemy alpha / wing (2)"}`)
	line = &dev.lines[dev.line_start]
	select_output_word(&dev, {line.sequence, int(line.spans[0].start) + 5})
	testing.expect(t, selected_text(&dev) == "enemy alpha / wing (2)",
		"semantic spans must take precedence over ordinary word boundaries")
	// A semantic identifier may cross the physical bounded log chunks.
	clear_command(&dev, "")
	identifier: [220]u8
	for &byte in identifier {byte = 'x'}
	identifier[100] = '-'
	data, _ := strings.concatenate({`{"id":"`, string(identifier[:]), `"}`}, context.temp_allocator)
	log_result(&dev, data)
	line = &dev.lines[dev.line_start]
	select_output_word(&dev, {line.sequence, int(line.spans[0].start) + 2})
	testing.expect(t, selected_text(&dev) == string(identifier[:]))
}

@(test)
output_selection_preserves_sequences_and_clamps_after_ring_eviction :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	info(&dev, "first selected")
	first := dev.log_sequence
	info(&dev, "second selected")
	last := dev.log_sequence
	select_output(&dev, {first, 6}, {last, 6})
	before := selected_text(&dev)
	info(&dev, "incoming output")
	testing.expect(t, selected_text(&dev) == before)
	for index in 0 ..< Max_Log_Lines + 5 {info(&dev, fmt.tprintf("retained %02d", index))}
	selected_text(&dev)
	start, end := output_range(&dev)
	oldest := dev.lines[dev.line_start].sequence
	testing.expect(t, start.sequence >= oldest && end.sequence >= oldest)
	testing.expect(t, start.sequence <= dev.log_sequence && end.sequence <= dev.log_sequence)
	testing.expect(t, start.offset >= 0 && end.offset >= 0)
}

@(test)
unicode_selection_never_splits_codepoint_bytes :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	info(&dev, "café βeta")
	select_output_word(&dev, {dev.log_sequence, 4})
	testing.expect(t, selected_text(&dev) == "café")
	select_output_word(&dev, {dev.log_sequence, 7})
	testing.expect(t, selected_text(&dev) == "βeta")
	start, end := text_word_range("café βeta", 4)
	testing.expect(t, start == 0 && end == 5)
}

@(test)
mouse_double_click_selects_words_and_semantic_output_ids :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	copy(dev.input[:], "inspect player Transform")
	dev.input_len = len("inspect player Transform")
	set_input_caret(&dev, dev.input_len)
	layout := view_layout(500, 500)
	view := build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	input_point := rl.Vector2{layout.input.x + 32 + 6 * 10, layout.input.y + 20}
	pointer_select(&dev, layout, view, input_point, true, true, false, 1, selection_view_measure)
	pointer_select(&dev, layout, view, input_point, false, false, false, 1.05, selection_view_measure)
	pointer_select(&dev, layout, view, input_point, true, true, false, 1.2, selection_view_measure)
	pointer_select(&dev, layout, view, input_point, false, false, false, 1.25, selection_view_measure)
	testing.expect(t, selected_text(&dev) == "player")
	log_result(&dev, `{"id":"enemy.alpha-1"}`)
	view = build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	line := &dev.lines[dev.line_start]
	output_point := rl.Vector2{layout.output.x + f32(line.spans[0].start + 5) * 6, layout.output.y + 10}
	pointer_select(&dev, layout, view, output_point, true, true, false, 2, selection_view_measure)
	pointer_select(&dev, layout, view, output_point, false, false, false, 2.05, selection_view_measure)
	pointer_select(&dev, layout, view, output_point, true, true, false, 2.2, selection_view_measure)
	pointer_select(&dev, layout, view, output_point, false, false, false, 2.25, selection_view_measure)
	testing.expect(t, selected_text(&dev) == "enemy.alpha-1")
}

@(test)
mouse_drag_selects_output_across_log_lines :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	info(&dev, "alpha beta")
	info(&dev, "gamma delta")
	layout := view_layout(500, 500)
	view := build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	start := rl.Vector2{layout.output.x + 6 * 6, layout.output.y + 10}
	end := rl.Vector2{layout.output.x + 5 * 6, layout.output.y + Row_Height + 10}
	pointer_select(&dev, layout, view, start, true, true, false, 1, selection_view_measure)
	pointer_select(&dev, layout, view, end, false, true, false, 1.1, selection_view_measure)
	pointer_select(&dev, layout, view, end, false, false, false, 1.2, selection_view_measure)
	testing.expect(t, selected_text(&dev) == "beta\ngamma")
}

@(test)
output_drag_pins_live_rows_while_new_logs_arrive :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	for index in 0 ..< 12 {info(&dev, fmt.tprintf("row%02d", index))}
	layout := view_layout(500, 500)
	view := build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	first, bottom := view.rows[view.first], view.rows[view.end - 1]
	start := rl.Vector2{layout.output.x + 2 * 6, layout.output.y + Row_Height + 10}
	end := rl.Vector2{layout.output.x + 4 * 6, layout.output.y + Row_Height * 2 + 10}
	pointer_select(&dev, layout, view, start, true, true, false, 1, selection_view_measure)
	testing.expect(t, dev.scroll_offset == 0 && dev.renderer.dragging_text)
	testing.expect(t, dev.scroll_anchor_sequence == bottom.sequence)
	info(&dev, "incoming")
	view = build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	testing.expect(t, view.rows[view.first].sequence == first.sequence)
	testing.expect(t, view.rows[view.end - 1].sequence == bottom.sequence)
	pointer_select(&dev, layout, view, end, false, true, false, 1.1, selection_view_measure)
	selection_start, selection_end := output_range(&dev)
	testing.expect(t, selection_start.sequence == first.sequence + 1 && selection_start.offset == 2)
	testing.expect(t, selection_end.sequence == first.sequence + 2 && selection_end.offset == 4)
	selected := selected_text(&dev)
	pointer_select(&dev, layout, view, end, false, false, false, 1.2, selection_view_measure)
	testing.expect(t, !dev.renderer.dragging_text)
	// Returning to latest ends the reading anchor without changing selection.
	scroll(&dev, -len(view.rows), len(view.rows), layout.visible_rows)
	view = build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	info(&dev, "latest after release")
	view = build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	testing.expect(t, dev.scroll_offset == 0 && dev.scroll_anchor_sequence == 0)
	testing.expect(t, view.rows[view.end - 1].sequence == dev.log_sequence)
	testing.expect(t, selected_text(&dev) == selected)
	// A click released before new output arrives must not leave LIVE pinned.
	pointer_select(&dev, layout, view, start, true, true, false, 2, selection_view_measure)
	pointer_select(&dev, layout, view, start, false, false, false, 2.1, selection_view_measure)
	view = build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	testing.expect(t, dev.scroll_offset == 0 && dev.scroll_anchor_sequence == 0)
	info(&dev, "another latest")
	view = build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	testing.expect(t, view.rows[view.end - 1].sequence == dev.log_sequence)
}

@(test)
mouse_shift_click_extends_input_and_reverse_word_drag_keeps_whole_words :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	copy(dev.input[:], "alpha beta gamma")
	dev.input_len = len("alpha beta gamma")
	set_input_caret(&dev, 0)
	layout := view_layout(500, 500)
	view := build_view(&dev, layout.output.width, layout.visible_rows, selection_view_measure)
	start := rl.Vector2{layout.input.x + 32 + 6 * 6, layout.input.y + 20}
	end := rl.Vector2{layout.input.x + 32 + 16 * 6, layout.input.y + 20}
	pointer_select(&dev, layout, view, start, true, true, false, 1, selection_view_measure)
	pointer_select(&dev, layout, view, start, false, false, false, 1.05, selection_view_measure)
	pointer_select(&dev, layout, view, end, true, true, true, 1.6, selection_view_measure)
	pointer_select(&dev, layout, view, end, false, false, false, 1.65, selection_view_measure)
	testing.expect(t, selected_text(&dev) == "beta gamma")
	word := rl.Vector2{layout.input.x + 32 + 13 * 6, layout.input.y + 20}
	pointer_select(&dev, layout, view, word, true, true, false, 2, selection_view_measure)
	pointer_select(&dev, layout, view, word, false, false, false, 2.05, selection_view_measure)
	pointer_select(&dev, layout, view, word, true, true, false, 2.2, selection_view_measure)
	testing.expect(t, selected_text(&dev) == "gamma")
	previous_word := rl.Vector2{layout.input.x + 32 + 2 * 6, layout.input.y + 20}
	pointer_select(&dev, layout, view, previous_word, false, true, false, 2.3, selection_view_measure)
	pointer_select(&dev, layout, view, previous_word, false, false, false, 2.4, selection_view_measure)
	testing.expect(t, dev.input_anchor == 16 && dev.input_caret == 0)
	testing.expect(t, selected_text(&dev) == "alpha beta gamma")
}

@(test)
json_boolean_word_selection_excludes_colons_but_semantic_ids_retain_them :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	data := `{"visible":true,"id":"enemy:alpha"}`
	start, end := text_word_range(data, 12)
	testing.expect(t, data[start:end] == "true")
	start, end = text_word_range(data, 10)
	testing.expect(t, data[start:end] == ":")
	dev := init()
	clear_command(&dev, "")
	log_result(&dev, data)
	line := &dev.lines[dev.line_start]
	select_output_word(&dev, {line.sequence, int(line.spans[0].start) + 5})
	testing.expect(t, selected_text(&dev) == "enemy:alpha")
}
