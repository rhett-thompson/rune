package console

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

// Match Rune's game UI without making the developer console depend on Clay.
Text_Color :: rl.Color{235, 241, 250, 255}
Muted_Color :: rl.Color{147, 163, 188, 255}
Surface_Color :: rl.Color{34, 45, 64, 255}
Accent_Color :: rl.Color{93, 225, 189, 255}
Selection_Color :: rl.Color{43, 100, 119, 255}
Font_Size :: f32(18)
Row_Height :: f32(25)
Font_Data :: #load("fonts/Inter.ttf")

Renderer :: struct {
	font, owned_font: rl.Font,
	input_scroll: f32,
	edit_revision: u64,
	caret_time: f64,
	wheel_remainder: f32,
	dragging_scrollbar: bool,
	drag_offset: f32,
	dragging_text, word_drag: bool,
	drag_target: Selection_Target,
	drag_input_start, drag_input_end: int,
	drag_output_start, drag_output_end: Log_Position,
	last_click_time: f64,
	last_click_pointer: rl.Vector2,
	last_click_target: Selection_Target,
	last_click_sequence: u64,
	last_drag_scroll_time: f64,
}

// Borrow a UI font. Refresh this after asset hot reload, before update/draw;
// the owner must keep it alive until rendering finishes. An empty font restores
// the embedded Inter font. The console never unloads borrowed fonts.
set_font :: proc(console: ^Console, font: rl.Font) -> bool {
	if font.baseSize == 0 && font.texture.id == 0 {
		console.renderer.font = {}
		console.renderer.input_scroll = 0
		return true
	}
	if font.baseSize <= 0 || font.texture.id == 0 {return false}
	if console.renderer.font.texture.id == font.texture.id && console.renderer.font.glyphs == font.glyphs {return true}
	console.renderer.font = font
	console.renderer.input_scroll = 0
	return true
}

// init() remains headless. The embedded atlas is created on the first open
// console frame, and is independent of project paths and asset hot reload.
ensure_renderer :: proc(console: ^Console) {
	if console.renderer.font.baseSize > 0 {return}
	if !rl.IsWindowReady() {return}
	if console.renderer.owned_font.baseSize <= 0 {
		codepoints: [190]rune
		count := 0
		for codepoint in 32 ..< 256 {
			if (codepoint >= 127 && codepoint < 160) || codepoint == 173 {continue}
			codepoints[count] = rune(codepoint)
			count += 1
		}
		loaded := rl.LoadFontFromMemory(".ttf", raw_data(Font_Data), i32(len(Font_Data)), 64,
			raw_data(codepoints[:count]), i32(count))
		if rl.IsFontValid(loaded) && loaded.texture.id != rl.GetFontDefault().texture.id {
			rl.SetTextureFilter(loaded.texture, .BILINEAR)
			console.renderer.owned_font = loaded
		}
	}
	console.renderer.font = console.renderer.owned_font
	if console.renderer.font.baseSize <= 0 {console.renderer.font = rl.GetFontDefault()}
}

destroy_renderer :: proc(console: ^Console) {
	if console.renderer.owned_font.baseSize > 0 {rl.UnloadFont(console.renderer.owned_font)}
	console.renderer = {}
}

text_width :: proc(console: ^Console, text: string, size: f32) -> f32 {
	if len(text) == 0 {return 0}
	c_text, _ := strings.clone_to_cstring(text, context.temp_allocator)
	return rl.MeasureTextEx(console.renderer.font, c_text, size, 0).x
}

Measure_Proc :: #type proc(text: string, size: f32) -> f32

Log_Row :: struct {
	sequence: u64,
	line_index: int,
	start, end: int,
}

Log_View :: struct {
	rows: []Log_Row, // Frame scratch; do not retain across frames.
	first, end: int,
}

// Wrap at word boundaries, falling back to complete UTF-8 codepoints for long
// paths/tokens. The reading anchor survives incoming messages and window resize.
build_view :: proc(console: ^Console, width: f32, visible_rows: int,
	measure: Measure_Proc = nil) -> Log_View {
	rows := make([dynamic]Log_Row, 0, console.line_count, context.temp_allocator)
	for index in 0 ..< console.line_count {
		line_index := (console.line_start + index) % Max_Log_Lines
		line := &console.lines[line_index]
		text := string(line.text[:line.len])
		if len(text) == 0 {append(&rows, Log_Row{line.sequence, line_index, 0, 0})}
		for start := 0; start < len(text); {
			end, word_break := start, -1
			pixels: f32
			for end < len(text) {
				character, size := utf8.decode_rune(text[end:])
				if character == '\n' {break}
				next := end + max(1, size)
				// raylib draws glyph advances without kerning; measuring each
				// codepoint keeps wrapping linear even for long command output.
				candidate := text[end:next]
				pixels += measure(candidate, Font_Size) if measure != nil else text_width(console, candidate, Font_Size)
				if pixels > max(1, width) && end > start {break}
				end = next
				if character == ' ' || character == '\t' {word_break = end}
			}
			if end < len(text) && text[end] != '\n' && word_break > start {end = word_break}
			append(&rows, Log_Row{line.sequence, line_index, start, end})
			start = end
			if start < len(text) && text[start] == '\n' {start += 1}
		}
	}
	visible := max(0, visible_rows)
	total := len(rows)
	if console.scroll_anchor_sequence > 0 {
		// An overwritten anchor falls back to the oldest retained page.
		console.scroll_offset = max(0, total - visible)
		for row, index in rows {
			if row.sequence == console.scroll_anchor_sequence &&
				(row.start <= console.scroll_anchor_byte &&
				 (row.end > console.scroll_anchor_byte || row.start == row.end)) {
				console.scroll_offset = total - index - 1
				break
			}
		}
	}
	console.scroll_offset = clamp(console.scroll_offset, 0, max(0, total - visible))
	first := max(0, total - visible - console.scroll_offset)
	end := min(total, first + visible)
	console.scroll_anchor_sequence = 0
	if (console.scroll_offset > 0 || (console.renderer.dragging_text && console.renderer.drag_target == .Output)) && end > first {
		console.scroll_anchor_sequence = rows[end - 1].sequence
		console.scroll_anchor_byte = rows[end - 1].start
	}
	return {rows[:], first, end}
}

scroll :: proc(console: ^Console, rows, total, visible_rows: int) {
	console.scroll_offset = clamp(console.scroll_offset + rows, 0, max(0, total - max(0, visible_rows)))
	console.scroll_anchor_sequence = 0
}

View_Layout :: struct {
	panel, output, input, track: rl.Rectangle,
	visible_rows: int,
}

view_layout :: proc(width, height: f32) -> View_Layout {
	margin := min(12, max(0, min(min(width, height) * 0.03, (min(width, height) - 1) / 2)))
	panel := rl.Rectangle{margin, margin, max(1, width - margin * 2),
		max(1, min(height - margin * 2, min(460, max(180, height * 0.6))))}
	padding := min(16, max(0, min(panel.width * 0.08, (panel.width - 1) / 2)))
	input_height := min(40, panel.height)
	foot_height := f32(30) if panel.height >= 140 else 0
	input := rl.Rectangle{panel.x + padding, max(panel.y, panel.y + panel.height - input_height - foot_height),
		max(1, panel.width - padding * 2), input_height}
	header_height := f32(58) if panel.height >= 140 else 0
	output := rl.Rectangle{panel.x + padding, panel.y + header_height, max(1, panel.width - padding * 2 - 16),
		max(0, input.y - (panel.y + header_height) - 12)}
	return {panel, output, input, {panel.x + panel.width - 22, output.y, 6, output.height},
		int(output.height / Row_Height)}
}

scrollbar_thumb :: proc(layout: View_Layout, total, offset: int) -> rl.Rectangle {
	if total <= layout.visible_rows {return layout.track}
	height := min(layout.track.height, max(24, layout.track.height * f32(layout.visible_rows) / f32(total)))
	maximum := max(1, total - layout.visible_rows)
	y := layout.track.y + (layout.track.height - height) * (1 - f32(offset) / f32(maximum))
	return {layout.track.x, y, layout.track.width, height}
}

update_view :: proc(console: ^Console) {
	ensure_renderer(console)
	layout := view_layout(f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
	view := build_view(console, layout.output.width, layout.visible_rows)
	total := len(view.rows)
	pointer := rl.GetMousePosition()
	if rl.CheckCollisionPointRec(pointer, layout.panel) {
		console.renderer.wheel_remainder += rl.GetMouseWheelMove() * 3
		rows := int(console.renderer.wheel_remainder)
		if rows != 0 {
			scroll(console, rows, total, layout.visible_rows)
			console.renderer.wheel_remainder -= f32(rows)
		}
	}
	if key_pressed_or_repeated(.PAGE_UP) {scroll(console, max(1, layout.visible_rows - 1), total, layout.visible_rows)}
	if key_pressed_or_repeated(.PAGE_DOWN) {scroll(console, -max(1, layout.visible_rows - 1), total, layout.visible_rows)}
	if (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) && rl.IsKeyPressed(.END) {
		scroll(console, -total, total, layout.visible_rows)
	}
	thumb := scrollbar_thumb(layout, total, console.scroll_offset)
	if rl.IsMouseButtonPressed(.LEFT) {
		hit_track := layout.track
		hit_track.x -= 6
		hit_track.width += 12
		if total > layout.visible_rows && rl.CheckCollisionPointRec(pointer, hit_track) {
			console.renderer.dragging_scrollbar = true
			console.renderer.drag_offset = pointer.y - thumb.y if pointer.y >= thumb.y && pointer.y <= thumb.y + thumb.height else thumb.height / 2
		}
	}
	if !rl.IsMouseButtonDown(.LEFT) {console.renderer.dragging_scrollbar = false}
	if console.renderer.dragging_scrollbar && layout.track.height > thumb.height {
		ratio := clamp((pointer.y - console.renderer.drag_offset - layout.track.y) / (layout.track.height - thumb.height), 0, 1)
		maximum := max(0, total - layout.visible_rows)
		scroll(console, int(math.round((1 - ratio) * f32(maximum))) - console.scroll_offset, total, layout.visible_rows)
	}
	// Holding a selection beyond the output viewport scrolls to more text.
	now := rl.GetTime()
	if console.renderer.dragging_text && console.renderer.drag_target == .Output &&
		rl.IsMouseButtonDown(.LEFT) && now - console.renderer.last_drag_scroll_time >= 0.05 {
		rows := 0
		if pointer.y < layout.output.y {rows = 1 + int((layout.output.y - pointer.y) / Row_Height)}
		if pointer.y > layout.output.y + layout.output.height {rows = -1 - int((pointer.y - layout.output.y - layout.output.height) / Row_Height)}
		if rows != 0 {
			scroll(console, clamp(rows, -4, 4), total, layout.visible_rows)
			console.renderer.last_drag_scroll_time = now
		}
	}
	view = build_view(console, layout.output.width, layout.visible_rows)
	pointer_select(console, layout, view, pointer, rl.IsMouseButtonPressed(.LEFT), rl.IsMouseButtonDown(.LEFT),
		rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT), now)
}

// Return the prefix width; drawing subtracts input_scroll from both text and
// caret. Use precisely the same font, size, and spacing for every measurement.
input_offset :: proc(console: ^Console, available_width: f32) -> f32 {
	caret := clamp(console.input_caret, 0, console.input_len)
	prefix := text_width(console, string(console.input[:caret]), Font_Size)
	full := text_width(console, string(console.input[:console.input_len]), Font_Size)
	available := max(1, available_width - 2)
	console.renderer.input_scroll = clamp(console.renderer.input_scroll, 0, max(0, full - available))
	if prefix < console.renderer.input_scroll {console.renderer.input_scroll = prefix}
	if prefix > console.renderer.input_scroll + available {console.renderer.input_scroll = prefix - available}
	return prefix
}

view_text :: proc(console: ^Console, text: string, position: rl.Vector2, size: f32, color: rl.Color) {
	c_text, _ := strings.clone_to_cstring(text, context.temp_allocator)
	rl.DrawTextEx(console.renderer.font, c_text, position, size, 0, color)
}

clip :: proc(rect: rl.Rectangle) {
	rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(max(0, rect.width)), i32(max(0, rect.height)))
}

draw_view :: proc(console: ^Console) {
	if !console.is_open {return}
	ensure_renderer(console)
	layout := view_layout(f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
	view := build_view(console, layout.output.width, layout.visible_rows)
	rl.DrawRectangleRounded({layout.panel.x, layout.panel.y + 4, layout.panel.width, layout.panel.height}, 0.05, 8, {0, 0, 0, 85})
	rl.DrawRectangleRounded(layout.panel, 0.05, 8, {20, 29, 44, 255})
	rl.DrawRectangleRoundedLinesEx(layout.panel, 0.05, 8, 1, {48, 66, 88, 255})
	clip(layout.panel)
	if layout.panel.height >= 140 {
		view_text(console, "Rune Console", {layout.panel.x + 16, layout.panel.y + 16}, 22, Text_Color)
		if layout.panel.width > 460 {
			hint := "` toggle   /   Esc close"
			view_text(console, hint, {layout.panel.x + layout.panel.width - 16 - text_width(console, hint, 14), layout.panel.y + 22}, 14, Muted_Color)
		}
		rl.DrawLineEx({layout.panel.x + 16, layout.panel.y + 48}, {layout.panel.x + layout.panel.width - 16, layout.panel.y + 48}, 1, {48, 66, 88, 255})
	}
	rl.EndScissorMode()
	clip(layout.output)
	for index in view.first ..< view.end {
		row := view.rows[index]
		line := &console.lines[row.line_index]
		position := rl.Vector2{layout.output.x, layout.output.y + f32(index - view.first) * Row_Height}
		first, last := row_selected_range(console, row)
		if first < last {
			left := text_width(console, string(line.text[row.start:first]), Font_Size)
			right := text_width(console, string(line.text[row.start:last]), Font_Size)
			rl.DrawRectangleV({position.x + left, position.y}, {right - left, Row_Height}, Selection_Color)
		}
		// Semantic spans carry their own byte ranges; selection and wrapping
		// share the same font metrics, keeping colored IDs aligned with text.
		cursor := row.start
		for span in line.spans[:line.span_count] {
			start, end := max(row.start, int(span.start)), min(row.end, int(span.end))
			if start >= end {continue}
			if cursor < start {
				left := text_width(console, string(line.text[row.start:cursor]), Font_Size)
				view_text(console, string(line.text[cursor:start]), {position.x + left, position.y}, Font_Size, color_for_level(line.level))
			}
			left := text_width(console, string(line.text[row.start:start]), Font_Size)
			view_text(console, string(line.text[start:end]), {position.x + left, position.y}, Font_Size, Accent_Color)
			cursor = end
		}
		if cursor < row.end {
			left := text_width(console, string(line.text[row.start:cursor]), Font_Size)
			view_text(console, string(line.text[cursor:row.end]), {position.x + left, position.y}, Font_Size, color_for_level(line.level))
		}
	}
	rl.EndScissorMode()
	if len(view.rows) > layout.visible_rows && layout.track.height > 0 {
		rl.DrawRectangleRounded(layout.track, 1, 4, Surface_Color)
		rl.DrawRectangleRounded(scrollbar_thumb(layout, len(view.rows), console.scroll_offset), 1, 4,
			Accent_Color if console.renderer.dragging_scrollbar else Muted_Color)
	}
	clip(layout.panel)
	rl.DrawRectangleRounded(layout.input, 0.3, 8, Surface_Color)
	rl.DrawRectangleRoundedLinesEx(layout.input, 0.3, 8, 1, {62, 107, 111, 255})
	view_text(console, ">", {layout.input.x + 12, layout.input.y + 10}, Font_Size, Accent_Color)
	rl.EndScissorMode()
	text_box := rl.Rectangle{min(layout.panel.x + layout.panel.width, layout.input.x + 32),
		layout.input.y + min(4, layout.input.height), max(0, layout.input.width - 44), max(0, layout.input.height - 8)}
	clip(text_box)
	caret_width := input_offset(console, text_box.width)
	position := rl.Vector2{text_box.x - console.renderer.input_scroll, layout.input.y + 10}
	if console.selection_target == .Input {
		start, end := input_selection(console)
		if start < end {
			left := text_width(console, string(console.input[:start]), Font_Size)
			right := text_width(console, string(console.input[:end]), Font_Size)
			rl.DrawRectangleV({position.x + left, position.y - 2}, {right - left, Font_Size + 5}, Selection_Color)
		}
	}
	view_text(console, string(console.input[:console.input_len]), position, Font_Size, Text_Color)
	if console.input_len == 0 {view_text(console, "Type help for commands", position, Font_Size, Muted_Color)}
	now := rl.GetTime()
	if console.renderer.edit_revision != console.edit_revision {
		console.renderer.edit_revision = console.edit_revision
		console.renderer.caret_time = now
	}
	if console.selection_target == .Input && int((now - console.renderer.caret_time) * 2) % 2 == 0 {
		rl.DrawRectangleV({position.x + caret_width, position.y}, {1.5, Font_Size + 2}, Accent_Color)
	}
	rl.EndScissorMode()
	clip(layout.panel)
	foot_y := layout.input.y + layout.input.height + 10
	busy := console.defer_reply || console.remote.result_len > 0
	if busy {
		view_text(console, "Command running; you can keep editing" if layout.panel.width > 620 else "Command running",
			{layout.input.x, foot_y}, 13, Muted_Color)
	} else if console.selection_target == .Output {
		view_text(console, "Ctrl+C copy   /   Ctrl+V paste to command" if layout.panel.width > 620 else "Ctrl+C copy / Ctrl+V paste",
			{layout.input.x, foot_y}, 13, Muted_Color)
	} else if layout.panel.width > 620 {
		view_text(console, "Enter run   /   Ctrl+C copy   /   Ctrl+V paste   /   PgUp PgDn scroll", {layout.input.x, foot_y}, 13, Muted_Color)
	} else {view_text(console, "Ctrl+C copy / Ctrl+V paste", {layout.input.x, foot_y}, 13, Muted_Color)}
	state := "RUNNING" if busy else "LIVE" if console.scroll_offset == 0 else fmt.tprintf("%d rows above latest", console.scroll_offset)
	if layout.panel.width > 300 {
		view_text(console, state, {layout.input.x + layout.input.width - text_width(console, state, 13), foot_y}, 13,
			Accent_Color if console.scroll_offset == 0 else Muted_Color)
	}
	rl.EndScissorMode()
}
