package console

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(test)
result_highlights_follow_json_fields_and_ignore_key_like_messages :: proc(t: ^testing.T) {
	data := `{"id":"player-main.2","details":{"parent":"root","children":["@12",7,null,{"message":"ignored","entity":"enemy"}]},"camera_2d":"cam","camera_3d":"","message":"{\"id\":\"fake\",\"children\":[\"also-fake\"]}","nested":[{"id":"first"},{"entity":"sec\"ond"}],"spare":"id: not-a-reference"}`
	spans := result_spans(data)
	expected := []string{"player-main.2", "root", "@12", "enemy", "cam", "first", `sec\"ond`}
	testing.expect(t, len(spans) == len(expected))
	for span, index in spans {
		if index >= len(expected) {break}
		testing.expect(t, data[span.start:span.end] == expected[index])
		testing.expect(t, data[span.start - 1] == '"' && data[span.end] == '"')
		testing.expect(t, !span.continues_before && !span.continues_after)
	}
	spans = result_spans(`{"\u0069d":"player","id":[],"children":[["nested-array"],"",false],"entity":42}`)
	testing.expect(t, len(spans) == 1, "Only direct string references should be highlighted")
}

@(test)
result_chunks_preserve_complete_utf8_and_split_id_metadata :: proc(t: ^testing.T) {
	dev := init()
	clear_command(&dev, "")
	padding: [181]u8
	for &byte in padding {byte = 'x'}
	data, _ := strings.concatenate({`{"id":"`, string(padding[:]), `é猫🙂","parent":"@42"}`}, context.temp_allocator)
	log_result(&dev, data)
	testing.expect(t, dev.line_count == 2)
	first := &dev.lines[dev.line_start]
	second := &dev.lines[(dev.line_start + 1) % Max_Log_Lines]
	testing.expect(t, first.len == 190, "The three-byte codepoint crossing byte 192 belongs to the next chunk")
	testing.expect(t, !first.continues_previous && second.continues_previous)
	testing.expect(t, first.span_count == 1 && second.span_count == 2)
	testing.expect(t, first.spans[0].start == 7 && int(first.spans[0].end) == first.len)
	testing.expect(t, !first.spans[0].continues_before && first.spans[0].continues_after)
	testing.expect(t, second.spans[0].start == 0 && int(second.spans[0].end) == len("猫🙂"))
	testing.expect(t, second.spans[0].continues_before && !second.spans[0].continues_after)
	testing.expect(t, string(second.text[second.spans[1].start:second.spans[1].end]) == "@42")
	chunks := make([]string, dev.line_count, context.temp_allocator)
	for index in 0 ..< dev.line_count {
		line := &dev.lines[(dev.line_start + index) % Max_Log_Lines]
		chunks[index] = string(line.text[:line.len])
		testing.expect(t, utf8.valid_string(chunks[index]))
		for span in line.spans[:line.span_count] {
			testing.expect(t, utf8.valid_string(chunks[index][span.start:span.end]))
		}
	}
	joined, _ := strings.concatenate(chunks, context.temp_allocator)
	testing.expect(t, joined == data, "Rejoining continued chunks must preserve every result byte")
}

@(test)
dense_entity_arrays_retain_all_spans_within_bounded_log_storage :: proc(t: ^testing.T) {
	dev := init()
	clear_command(&dev, "")
	children: [100]string
	for &child in children {child = "a"}
	set_result(&dev, struct {children: []string}{children[:]})
	total := 0
	for index in 0 ..< dev.line_count {
		line := &dev.lines[(dev.line_start + index) % Max_Log_Lines]
		testing.expect(t, line.span_count <= Max_Line_Highlights)
		for span in line.spans[:line.span_count] {
			testing.expect(t, string(line.text[span.start:span.end]) == "a")
			total += 1
		}
	}
	testing.expect(t, total == len(children))
}

@(test)
result_metadata_does_not_change_remote_data_or_survive_log_slot_reuse :: proc(t: ^testing.T) {
	Payload :: struct {id, parent, message: string, children: []string}
	payload := Payload{"knight-main.2", "@42", `{"id":"fake"}`, {"first", "second"}}
	dev := init()
	clear_command(&dev, "")
	dev.remote.result_len = 1
	set_result(&dev, payload)
	testing.expect(t, dev.line_count == 0, "Remote results keep their structured data without logging JSON chunks")
	encoded, encode_error := json.marshal(dev.result_data, allocator = context.temp_allocator)
	restored: Payload
	decode_error := json.unmarshal(encoded, &restored, allocator = context.temp_allocator)
	testing.expect(t, encode_error == nil && decode_error == nil)
	testing.expect(t, restored.id == payload.id && restored.parent == payload.parent && restored.message == payload.message)
	testing.expect(t, len(restored.children) == 2 && restored.children[0] == "first" && restored.children[1] == "second")
	dev.remote.result_len = 0
	log_result(&dev, `{"id":"player"}`)
	reused_index := dev.line_start
	testing.expect(t, dev.lines[reused_index].span_count == 1)
	dev.lines[reused_index].continues_previous = true
	for index in 0 ..< Max_Log_Lines {info(&dev, "ordinary message")}
	line := &dev.lines[reused_index]
	testing.expect(t, line.span_count == 0 && !line.continues_previous)
	testing.expect(t, string(line.text[:line.len]) == "ordinary message")
	logs := read_logs(&dev, 0)
	testing.expect(t, logs.entries[len(logs.entries)-1].message == "ordinary message")
}

@(test)
semantic_id_selection_spans_multiple_chunks_and_survives_partial_eviction :: proc(t: ^testing.T) {
	dev := init()
	clear_command(&dev, "")
	identifier: [520]u8
	for &byte in identifier {byte = 'x'}
	identifier[190], identifier[390] = ' ', '%'
	data, _ := strings.concatenate({`{"id":"`, string(identifier[:]), `"}`}, context.temp_allocator)
	log_result(&dev, data)
	testing.expect(t, dev.line_count == 3)
	for index in 0 ..< dev.line_count {
		line := &dev.lines[(dev.line_start + index) % Max_Log_Lines]
		select_output_word(&dev, {line.sequence, int(line.spans[0].start) + 1})
		testing.expect(t, selected_text(&dev) == string(identifier[:]), "Clicks in any chunk should select the complete semantic ID")
	}
	for index in 0 ..< Max_Log_Lines - 1 {info(&dev, "ordinary message")}
	oldest := &dev.lines[dev.line_start]
	testing.expect(t, oldest.continues_previous && oldest.spans[0].continues_before)
	select_output_word(&dev, {oldest.sequence, int(oldest.spans[0].start) + 1})
	remaining := string(oldest.text[oldest.spans[0].start:oldest.spans[0].end])
	testing.expect(t, selected_text(&dev) == remaining, "An evicted ID prefix should clamp selection to its retained suffix")
}

@(test)
ordinary_logs_and_long_command_echo_keep_utf8_prefixes_complete :: proc(t: ^testing.T) {
	dev := init()
	clear_command(&dev, "")
	prefix: [191]u8
	for &byte in prefix {byte = 'x'}
	message, _ := strings.concatenate({string(prefix[:]), "é tail"}, context.temp_allocator)
	info(&dev, message)
	line := &dev.lines[dev.line_start]
	testing.expect(t, line.len == len(prefix) && utf8.valid_string(string(line.text[:line.len])))
	made := make_line(.Info, message)
	testing.expect(t, made.len == len(prefix) && utf8.valid_string(string(made.text[:made.len])))
	// A partial part ends the logical prefix; later parts must not replace the
	// excluded codepoint merely because one byte remains in the output buffer.
	log_parts(&dev, .Info, {string(prefix[:]), "é", "z"})
	line = &dev.lines[(dev.line_start + 1) % Max_Log_Lines]
	testing.expect(t, string(line.text[:line.len]) == string(prefix[:]))
	clear_command(&dev, "")
	command, _ := strings.concatenate({"help ", string(prefix[:184]), "é", string(prefix[:60])}, context.temp_allocator)
	testing.expect(t, insert_text(&dev, command))
	submit(&dev)
	line = &dev.lines[dev.line_start]
	testing.expect(t, line.len == 191 && utf8.valid_string(string(line.text[:line.len])))
	echo, _ := strings.concatenate({"> ", command}, context.temp_allocator)
	testing.expect(t, string(line.text[:line.len]) == echo[:191])
	select_output(&dev, {line.sequence, 0}, {line.sequence, line.len})
	testing.expect(t, utf8.valid_string(selected_text(&dev)), "Copied command echoes must remain valid pasteable text")
	testing.expect(t, string(dev.history[0].text[:dev.history[0].len]) == command, "Output truncation must preserve the submitted command")
}
