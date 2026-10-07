package console

import rl "vendor:raylib"

output_hit :: proc(console: ^Console, layout: View_Layout, view: Log_View,
	pointer: rl.Vector2, for_word: bool, measure: Measure_Proc) -> Log_Position {
	if view.end <= view.first {return {}}
	index := clamp(view.first + int((pointer.y - layout.output.y) / Row_Height), view.first, view.end - 1)
	row := view.rows[index]
	line := &console.lines[row.line_index]
	offset := text_hit(console, string(line.text[row.start:row.end]), pointer.x - layout.output.x, for_word, measure)
	return {row.sequence, row.start + offset}
}

// Mouse sampling is explicit so wrapped text selection, double clicks and
// dragging can be validated without sending input to a desktop window.
pointer_select :: proc(console: ^Console, layout: View_Layout, view: Log_View,
	pointer: rl.Vector2, pressed, down, extend: bool, now: f64,
	measure: Measure_Proc = nil) {
	renderer := &console.renderer
	if pressed && !renderer.dragging_scrollbar {
		in_input := rl.CheckCollisionPointRec(pointer, layout.input)
		in_output := rl.CheckCollisionPointRec(pointer, layout.output) && view.end > view.first
		if !in_input && !in_output {renderer.dragging_text = false; return}
		target := Selection_Target.Input if in_input else Selection_Target.Output
		position: Log_Position
		if in_output {position = output_hit(console, layout, view, pointer, false, measure)}
		delta := rl.Vector2{pointer.x - renderer.last_click_pointer.x, pointer.y - renderer.last_click_pointer.y}
		double_click := renderer.last_click_time > 0 && now - renderer.last_click_time >= 0 &&
			now - renderer.last_click_time <= 0.35 && delta.x * delta.x + delta.y * delta.y <= 25 &&
			renderer.last_click_target == target && renderer.last_click_sequence == position.sequence
		renderer.last_click_time = now
		renderer.last_click_pointer = pointer
		renderer.last_click_target = target
		renderer.last_click_sequence = position.sequence
		renderer.dragging_text = true
		renderer.word_drag = double_click
		renderer.drag_target = target
		renderer.last_drag_scroll_time = now
		if in_input {
			text := string(console.input[:console.input_len])
			x := pointer.x - layout.input.x - 32 + renderer.input_scroll
			if double_click {
				select_input_word(console, text_hit(console, text, x, true, measure))
				renderer.drag_input_start, renderer.drag_input_end = input_selection(console)
			} else {
				keep_anchor := extend && console.selection_target == .Input
				set_input_caret(console, text_hit(console, text, x, false, measure), keep_anchor)
			}
		} else if double_click {
			select_output_word(console, output_hit(console, layout, view, pointer, true, measure))
			renderer.drag_output_start, renderer.drag_output_end = output_range(console)
		} else {
			anchor := console.output_selection.anchor if extend && console.selection_target == .Output else position
			select_output(console, anchor, position)
		}
		if in_output && view.end > view.first {
			console.scroll_anchor_sequence = view.rows[view.end - 1].sequence
			console.scroll_anchor_byte = view.rows[view.end - 1].start
		}
	}
	if !down {renderer.dragging_text = false; return}
	if !renderer.dragging_text || pressed {return}
	if renderer.drag_target == .Input {
		text := string(console.input[:console.input_len])
		x := pointer.x - layout.input.x - 32 + renderer.input_scroll
		if renderer.word_drag {
			start, end := text_word_range(text, text_hit(console, text, x, true, measure))
			anchor, caret := renderer.drag_input_start, renderer.drag_input_end
			if end <= renderer.drag_input_start {anchor, caret = renderer.drag_input_end, start}
			if start >= renderer.drag_input_end {caret = end}
			set_input_caret(console, anchor)
			set_input_caret(console, caret, true)
		} else {set_input_caret(console, text_hit(console, text, x, false, measure), true)}
	} else {
		position := output_hit(console, layout, view, pointer, renderer.word_drag, measure)
		if renderer.word_drag {
			start, end := output_word_range(console, position)
			anchor, caret := renderer.drag_output_start, renderer.drag_output_end
			if !position_before(renderer.drag_output_start, end) {anchor, caret = renderer.drag_output_end, start}
			if !position_before(start, renderer.drag_output_end) {caret = end}
			select_output(console, anchor, caret)
		} else {select_output(console, console.output_selection.anchor, position)}
	}
}
