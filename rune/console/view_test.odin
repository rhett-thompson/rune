package console

import "core:fmt"
import "core:mem"
import "core:testing"

view_test_measure :: proc(text: string, size: f32) -> f32 {
	width: f32
	for _ in text {width += 6}
	return width
}

@(test)
log_view_wraps_lines_without_splitting_utf8 :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	info(&dev, "abcdefghijkl")
	view := build_view(&dev, 24, 2, view_test_measure)
	testing.expect(t, len(view.rows) == 3)
	testing.expect(t, view.first == 1 && view.end == 3)
	for row, index in view.rows {
		testing.expect(t, row.start == index * 4 && row.end == (index + 1) * 4)
		testing.expect(t, row.sequence == dev.log_sequence)
	}
	clear_command(&dev, "")
	info(&dev, "éééé")
	view = build_view(&dev, 12, 8, view_test_measure)
	testing.expect(t, len(view.rows) == 2)
	if len(view.rows) == 2 {
		testing.expect(t, view.rows[0].start == 0 && view.rows[0].end == 4)
		testing.expect(t, view.rows[1].start == 4 && view.rows[1].end == 8)
	}
	// A viewport narrower than one glyph must still advance through the log.
	view = build_view(&dev, 1, 8, view_test_measure)
	testing.expect(t, len(view.rows) == 4)
	for row in view.rows {testing.expect(t, row.end - row.start == 2)}
}

@(test)
scrolled_log_view_preserves_reading_position_when_output_arrives :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	for index in 0 ..< 12 {info(&dev, fmt.tprintf("row%02d", index))}
	view := build_view(&dev, 36, 4, view_test_measure)
	scroll(&dev, 5, len(view.rows), 4)
	view = build_view(&dev, 36, 4, view_test_measure)
	bottom := view.rows[view.end - 1]
	info(&dev, "new output that wraps across several rows")
	view = build_view(&dev, 36, 4, view_test_measure)
	anchored := view.rows[view.end - 1]
	testing.expect(t, anchored.sequence == bottom.sequence && anchored.start == bottom.start)
	testing.expect(t, dev.scroll_offset > 5)
	// Following the tail resumes only after scrolling explicitly back down.
	scroll(&dev, -10000, len(view.rows), 4)
	view = build_view(&dev, 36, 4, view_test_measure)
	testing.expect(t, dev.scroll_offset == 0 && view.end == len(view.rows))
	info(&dev, "latest")
	view = build_view(&dev, 36, 4, view_test_measure)
	testing.expect(t, view.rows[view.end - 1].sequence == dev.log_sequence)
}

@(test)
log_scroll_bounds_and_retained_ring_entries_remain_valid :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	view := build_view(&dev, 90, 4, view_test_measure)
	scroll(&dev, 10000, len(view.rows), 4)
	testing.expect(t, dev.scroll_offset == 0 && view.first == 0 && view.end == 0)
	for index in 0 ..< 30 {info(&dev, fmt.tprintf("log row %02d", index))}
	view = build_view(&dev, 90, 4, view_test_measure)
	scroll(&dev, 10000, len(view.rows), 4)
	view = build_view(&dev, 90, 4, view_test_measure)
	testing.expect(t, view.first == 0 && view.end == 4)
	testing.expect(t, dev.scroll_offset == len(view.rows) - 4)
	// More output than the ring can retain drops old anchors safely.
	for index in 0 ..< Max_Log_Lines + 8 {info(&dev, fmt.tprintf("replacement %02d", index))}
	view = build_view(&dev, 90, 4, view_test_measure)
	testing.expect(t, dev.line_count == Max_Log_Lines)
	testing.expect(t, view.first >= 0 && view.end <= len(view.rows) && view.first < view.end)
	testing.expect(t, dev.scroll_offset >= 0 && dev.scroll_offset <= max(0, len(view.rows) - 4))
	for row in view.rows {
		testing.expect(t, row.line_index >= 0 && row.line_index < Max_Log_Lines)
		testing.expect(t, dev.lines[row.line_index].sequence == row.sequence)
	}
	clear_command(&dev, "")
	view = build_view(&dev, 90, 4, view_test_measure)
	testing.expect(t, len(view.rows) == 0 && dev.scroll_offset == 0)
}

@(test)
log_view_resize_keeps_anchor_visible_and_handles_tiny_height :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	clear_command(&dev, "")
	for index in 0 ..< 14 {info(&dev, fmt.tprintf("%02d abcdefghijklmnopqrstuvwxyz", index))}
	view := build_view(&dev, 90, 5, view_test_measure)
	scroll(&dev, 7, len(view.rows), 5)
	view = build_view(&dev, 90, 5, view_test_measure)
	sequence := view.rows[view.end - 1].sequence
	view = build_view(&dev, 30, 5, view_test_measure)
	testing.expect(t, view.rows[view.end - 1].sequence == sequence)
	testing.expect(t, view.first >= 0 && view.end <= len(view.rows) && view.end - view.first <= 5)
	view = build_view(&dev, 180, 1, view_test_measure)
	testing.expect(t, view.end - view.first == 1)
	testing.expect(t, view.rows[view.end - 1].sequence == sequence)
	view = build_view(&dev, 180, 0, view_test_measure)
	testing.expect(t, view.first >= 0 && view.end >= view.first && view.end <= len(view.rows))
}

@(test)
tiny_console_layout_keeps_input_inside_the_panel :: proc(t: ^testing.T) {
	for size in ([5][2]f32{{180, 90}, {96, 54}, {36, 30}, {8, 8}, {1, 1}}) {
		layout := view_layout(size[0], size[1])
		testing.expect(t, layout.input.x >= layout.panel.x && layout.input.y >= layout.panel.y)
		testing.expect(t, layout.input.x + layout.input.width <= layout.panel.x + layout.panel.width + 0.001)
		testing.expect(t, layout.input.y + layout.input.height <= layout.panel.y + layout.panel.height + 0.001)
		testing.expect(t, layout.input.width > 0 && layout.input.height > 0)
		testing.expect(t, layout.visible_rows >= 0 && layout.output.height >= 0)
		thumb := scrollbar_thumb(layout, 100, 25)
		testing.expect(t, thumb.height >= 0 && thumb.y >= layout.track.y)
		testing.expect(t, thumb.y + thumb.height <= layout.track.y + layout.track.height + 0.001)
	}
}
