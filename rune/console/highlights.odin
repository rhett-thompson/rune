package console

import "core:encoding/json"
import "core:strings"

// Byte offsets into a log line. Split result chunks retain the connection to
// the rest of an ID so word selection can select its complete encoded text.
Text_Span :: struct {
	start, end: int,
	continues_before, continues_after: bool,
}

// A line contains at most 192 bytes, so local offsets fit in a byte. Keep the
// retained metadata compact: Console is also returned and embedded by value.
Log_Span :: struct {
	start, end: u8,
	continues_before, continues_after: bool,
}

JSON_Highlight_Kind :: enum {None, String, Strings}

JSON_Highlight_Parser :: struct {
	data: string,
	cursor: int,
	spans: [dynamic]Text_Span,
}

// Result data is already valid JSON. Parse its structure to highlight entity
// references without treating key-like text inside a log message as a field.
result_spans :: proc(data: string) -> []Text_Span {
	parser := JSON_Highlight_Parser {
		data = data,
		spans = make([dynamic]Text_Span, context.temp_allocator),
	}
	parse_highlight_value(&parser, .None)
	return parser.spans[:]
}

highlight_key_kind :: proc(encoded: string) -> JSON_Highlight_Kind {
	key := encoded[1:len(encoded)-1]
	if strings.contains(key, "\\") {
		if json.unmarshal(transmute([]u8)encoded, &key, allocator = context.temp_allocator) != nil {return .None}
	}
	switch key {
	case "id", "parent", "entity", "camera_2d", "camera_3d": return .String
	case "children": return .Strings
	}
	return .None
}

skip_highlight_whitespace :: proc(parser: ^JSON_Highlight_Parser) {
	for parser.cursor < len(parser.data) {
		switch parser.data[parser.cursor] {
		case ' ', '\t', '\n', '\r': parser.cursor += 1
		case: return
		}
	}
}

parse_highlight_string :: proc(parser: ^JSON_Highlight_Parser) -> (start, end: int) {
	start = parser.cursor
	parser.cursor += 1
	for parser.cursor < len(parser.data) {
		character := parser.data[parser.cursor]
		parser.cursor += 1
		if character == '"' {break}
		if character == '\\' {parser.cursor = min(parser.cursor + 1, len(parser.data))}
	}
	return start, parser.cursor
}

parse_highlight_value :: proc(parser: ^JSON_Highlight_Parser, kind: JSON_Highlight_Kind) {
	skip_highlight_whitespace(parser)
	if parser.cursor >= len(parser.data) {return}
	switch parser.data[parser.cursor] {
	case '"':
		start, end := parse_highlight_string(parser)
		if kind == .String && end > start + 2 {append(&parser.spans, Text_Span{start = start + 1, end = end - 1})}
	case '{':
		parser.cursor += 1
		skip_highlight_whitespace(parser)
		for parser.cursor < len(parser.data) && parser.data[parser.cursor] != '}' {
			key_start, key_end := parse_highlight_string(parser)
			skip_highlight_whitespace(parser)
			parser.cursor += 1 // Colon after the object key.
			parse_highlight_value(parser, highlight_key_kind(parser.data[key_start:key_end]))
			skip_highlight_whitespace(parser)
			if parser.cursor >= len(parser.data) || parser.data[parser.cursor] != ',' {break}
			parser.cursor += 1
			skip_highlight_whitespace(parser)
		}
		if parser.cursor < len(parser.data) {parser.cursor += 1}
	case '[':
		parser.cursor += 1
		skip_highlight_whitespace(parser)
		for parser.cursor < len(parser.data) && parser.data[parser.cursor] != ']' {
			child_kind: JSON_Highlight_Kind = .None
			if kind == .Strings {child_kind = .String}
			parse_highlight_value(parser, child_kind)
			skip_highlight_whitespace(parser)
			if parser.cursor >= len(parser.data) || parser.data[parser.cursor] != ',' {break}
			parser.cursor += 1
			skip_highlight_whitespace(parser)
		}
		if parser.cursor < len(parser.data) {parser.cursor += 1}
	case:
		for parser.cursor < len(parser.data) {
			switch parser.data[parser.cursor] {
			case ',', '}', ']', ' ', '\t', '\n', '\r': return
			case: parser.cursor += 1
			}
		}
	}
}

result_chunk_end :: proc(data: string, start: int, limit := Max_Line_Length) -> int {
	end := min(start + max(0, limit), len(data))
	// A UTF-8 continuation byte belongs to the preceding codepoint. Leave that
	// complete codepoint for the next chunk, preserving readable copied text.
	for end > start && end < len(data) && data[end] & 0xc0 == 0x80 {end -= 1}
	return end
}

log_result :: proc(console: ^Console, data: string) {
	spans := result_spans(data)
	span_index := 0
	for start := 0; start < len(data); {
		end := result_chunk_end(data, start)
		info(console, data[start:end])
		line := &console.lines[(console.line_start + console.line_count - 1) % Max_Log_Lines]
		line.continues_previous = start > 0
		for span_index < len(spans) && spans[span_index].end <= start {span_index += 1}
		for index := span_index; index < len(spans) && spans[index].start < end; index += 1 {
			span := spans[index]
			if line.span_count == Max_Line_Highlights {break}
			line.spans[line.span_count] = Log_Span {
				start = u8(max(start, span.start) - start),
				end = u8(min(end, span.end) - start),
				continues_before = span.start < start,
				continues_after = span.end > end,
			}
			line.span_count += 1
		}
		start = end
	}
}
