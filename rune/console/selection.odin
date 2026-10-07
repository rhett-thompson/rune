package console

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import rl "vendor:raylib"

Selection_Target :: enum {Input, Output}

// Sequence numbers keep selections attached to retained text when logs arrive
// or the physical ring rotates. Offsets address the original UTF-8 log bytes.
Log_Position :: struct {sequence: u64, offset: int}
Output_Selection :: struct {anchor, caret: Log_Position}

position_before :: proc(a, b: Log_Position) -> bool {
	return a.sequence < b.sequence || (a.sequence == b.sequence && a.offset < b.offset)
}

log_line :: proc(console: ^Console, sequence: u64) -> ^Log_Line {
	if console.line_count == 0 {return nil}
	first := console.lines[console.line_start].sequence
	if sequence < first || sequence >= first + u64(console.line_count) {return nil}
	return &console.lines[(console.line_start + int(sequence - first)) % Max_Log_Lines]
}

text_boundary :: proc(text: string, offset: int) -> int {
	result := clamp(offset, 0, len(text))
	for result > 0 && result < len(text) && text[result] & 0xc0 == 0x80 {result -= 1}
	return result
}

clamp_position :: proc(console: ^Console, position: Log_Position) -> Log_Position {
	if console.line_count == 0 {return {}}
	first := &console.lines[console.line_start]
	last := &console.lines[(console.line_start + console.line_count - 1) % Max_Log_Lines]
	if position.sequence < first.sequence {return {first.sequence, 0}}
	if position.sequence > last.sequence {return {last.sequence, last.len}}
	line := log_line(console, position.sequence)
	return {position.sequence, text_boundary(string(line.text[:line.len]), position.offset)}
}

output_range :: proc(console: ^Console) -> (start, end: Log_Position) {
	start = clamp_position(console, console.output_selection.anchor)
	end = clamp_position(console, console.output_selection.caret)
	if position_before(end, start) {start, end = end, start}
	return
}

select_output :: proc(console: ^Console, anchor, caret: Log_Position) {
	console.selection_target = .Output
	console.output_selection = {clamp_position(console, anchor), clamp_position(console, caret)}
}

// Identifier/path punctuation stays together, including Odin field names and
// runtime @handles. Quotes, brackets and commas remain separate from tokens.
word_class :: proc(character: rune) -> int {
	if unicode.is_space(character) {return 0}
	if unicode.is_letter(character) || unicode.is_digit(character) ||
		character > 127 || character == '_' || character == '-' || character == '.' ||
		character == '@' || character == '/' || character == '\\' {return 1}
	return 2
}

text_word_range :: proc(text: string, offset: int) -> (start, end: int) {
	if len(text) == 0 {return 0, 0}
	start = text_boundary(text, offset)
	if start == len(text) {_, size := utf8.decode_last_rune(text); start -= max(1, size)}
	character, size := utf8.decode_rune(text[start:])
	class := word_class(character)
	end = start + max(1, size)
	if class == 2 {return}
	for start > 0 {
		previous, previous_size := utf8.decode_last_rune(text[:start])
		if word_class(previous) != class {break}
		start -= max(1, previous_size)
	}
	for end < len(text) {
		next, next_size := utf8.decode_rune(text[end:])
		if word_class(next) != class {break}
		end += max(1, next_size)
	}
	return
}

// Prefer explicit result spans over token guessing, including encoded IDs
// containing spaces or punctuation, and spans crossing result log chunks.
output_word_range :: proc(console: ^Console, original_position: Log_Position) -> (start, end: Log_Position) {
	position := clamp_position(console, original_position)
	line := log_line(console, position.sequence)
	if line == nil {return position, position}
	for span in line.spans[:line.span_count] {
		if position.offset < int(span.start) || position.offset >= int(span.end) {continue}
		start, end = {position.sequence, int(span.start)}, {position.sequence, int(span.end)}
		before, after := span.continues_before, span.continues_after
		for before {
			previous := log_line(console, start.sequence - 1)
			if previous == nil {break}
			before = false
			for previous_span in previous.spans[:previous.span_count] {
				if !previous_span.continues_after {continue}
				start = {previous.sequence, int(previous_span.start)}
				before = previous_span.continues_before
				break
			}
		}
		for after {
			next := log_line(console, end.sequence + 1)
			if next == nil {break}
			after = false
			for next_span in next.spans[:next.span_count] {
				if !next_span.continues_before {continue}
				end = {next.sequence, int(next_span.end)}
				after = next_span.continues_after
				break
			}
		}
		return
	}
	// A visual/chunk break does not create a word boundary. Join only chunks of
	// the same original result; ordinary log entries remain independent lines.
	first, last := line.sequence, line.sequence
	for current := line; current.continues_previous; {
		previous := log_line(console, first - 1)
		if previous == nil {break}
		first, current = previous.sequence, previous
	}
	for next := log_line(console, last + 1); next != nil && next.continues_previous; next = log_line(console, last + 1) {
		last = next.sequence
	}
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	clicked := 0
	for sequence in first ..= last {
		part := log_line(console, sequence)
		if sequence == position.sequence {clicked = strings.builder_len(builder) + position.offset}
		strings.write_string(&builder, string(part.text[:part.len]))
	}
	word_start, word_end := text_word_range(strings.to_string(builder), clicked)
	base := 0
	start, end = {first, 0}, {last, log_line(console, last).len}
	for sequence in first ..= last {
		part := log_line(console, sequence)
		if word_start >= base && word_start < base + part.len {start = {sequence, word_start - base}}
		if word_end > base && word_end <= base + part.len {end = {sequence, word_end - base}}
		base += part.len
	}
	return
}

select_output_word :: proc(console: ^Console, position: Log_Position) {
	start, end := output_word_range(console, position)
	select_output(console, start, end)
}

select_all :: proc(console: ^Console) {
	if console.selection_target == .Input {
		set_input_caret(console, 0)
		set_input_caret(console, console.input_len, true)
		return
	}
	if console.line_count == 0 {console.output_selection = {}; return}
	first := &console.lines[console.line_start]
	last := &console.lines[(console.line_start + console.line_count - 1) % Max_Log_Lines]
	select_output(console, {first.sequence, 0}, {last.sequence, last.len})
}

// Selection copies original text. Soft wraps add nothing; independent log
// entries are separated by newlines, while result chunks rejoin verbatim.
selected_text :: proc(console: ^Console) -> string {
	if console.selection_target == .Input {
		start, end := input_selection(console)
		result, _ := strings.clone(string(console.input[start:end]), context.temp_allocator)
		return result
	}
	start, end := output_range(console)
	if start == end || start.sequence == 0 {return ""}
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	for sequence in start.sequence ..= end.sequence {
		line := log_line(console, sequence)
		if line == nil {continue}
		if sequence > start.sequence && !line.continues_previous {strings.write_byte(&builder, '\n')}
		first := start.offset if sequence == start.sequence else 0
		last := end.offset if sequence == end.sequence else line.len
		strings.write_string(&builder, string(line.text[first:last]))
	}
	return strings.to_string(builder)
}

copy_selection :: proc(console: ^Console) -> bool {
	text := selected_text(console)
	if len(text) == 0 {return false}
	c_text, _ := strings.clone_to_cstring(text, context.temp_allocator)
	rl.SetClipboardText(c_text)
	return true
}

// Shared geometry for caret placement and selection highlight rectangles.
// Word hit-testing uses the touched glyph; carets use its midpoint boundary.
text_hit :: proc(console: ^Console, text: string, x: f32, for_word: bool,
	measure: Measure_Proc = nil) -> int {
	left: f32
	for offset := 0; offset < len(text); {
		_, size := utf8.decode_rune(text[offset:])
		next := offset + max(1, size)
		right := measure(text[:next], Font_Size) if measure != nil else text_width(console, text[:next], Font_Size)
		threshold := right if for_word else (left + right) / 2
		if x < threshold {return offset}
		offset, left = next, right
	}
	return len(text)
}

row_selected_range :: proc(console: ^Console, row: Log_Row) -> (first, last: int) {
	if console.selection_target != .Output {return row.start, row.start}
	start, end := output_range(console)
	if row.sequence < start.sequence || row.sequence > end.sequence {return row.start, row.start}
	first, last = row.start, row.end
	if row.sequence == start.sequence {first = max(first, start.offset)}
	if row.sequence == end.sequence {last = min(last, end.offset)}
	last = max(first, last)
	return
}
