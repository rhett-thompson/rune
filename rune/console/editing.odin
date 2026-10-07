package console

import rl "vendor:raylib"
import "core:unicode"
import "core:unicode/utf8"

// Input is a bounded single-line UTF-8 command. Caret and anchor are byte
// indices on codepoint boundaries, preserving the remote command byte limit.
History_Line :: struct {
	text: [Max_Input_Length]u8,
	len: int,
}

// The input still shows a recalled command removed by a remote append. Down
// should visit the oldest retained successor before eventually restoring draft.
History_Evicted_Index :: -2

Edit_Action :: enum {
	Backspace,
	Delete,
	Left,
	Right,
	Home,
	End,
	Previous_History,
	Next_History,
	Select_All,
}

input_selection :: proc(console: ^Console) -> (start, end: int) {
	caret := input_boundary(console, console.input_caret)
	anchor := input_boundary(console, console.input_anchor)
	return min(caret, anchor), max(caret, anchor)
}

// extend retains the selection anchor, as Shift does when moving the caret.
set_input_caret :: proc(console: ^Console, caret: int, extend := false) {
	position := input_boundary(console, caret)
	anchor := input_boundary(console, console.input_anchor) if extend else position
	if console.input_caret != position || console.input_anchor != anchor || console.selection_target != .Input {
		console.input_caret = position
		console.input_anchor = anchor
		console.selection_target = .Input
		console.edit_revision += 1
	}
}

select_input_word :: proc(console: ^Console, offset: int) {
	start, end := text_word_range(string(console.input[:console.input_len]), offset)
	set_input_caret(console, start)
	set_input_caret(console, end, true)
}

// edit is headless. Ctrl moves/deletes whitespace-delimited command tokens;
// Shift extends selections. A plain arrow collapses a selection toward its edge.
edit :: proc(console: ^Console, action: Edit_Action, by_word := false, extend := false) -> bool {
	old_revision := console.edit_revision
	set_input_caret(console, console.input_caret, true)
	selection_start, selection_end := input_selection(console)
	switch action {
	case .Backspace:
		if selection_start != selection_end {
			remove_input(console, selection_start, selection_end)
		} else if console.input_caret > 0 {
			start := previous_input_character(console, console.input_caret)
			if by_word {start = previous_word(console)}
			remove_input(console, start, console.input_caret)
		}
	case .Delete:
		if selection_start != selection_end {
			remove_input(console, selection_start, selection_end)
		} else if console.input_caret < console.input_len {
			end := next_input_character(console, console.input_caret)
			if by_word {end = next_word(console)}
			remove_input(console, console.input_caret, end)
		}
	case .Left:
		caret := previous_input_character(console, console.input_caret)
		if by_word {caret = previous_word(console)}
		if !extend && selection_start != selection_end {caret = selection_start}
		set_input_caret(console, caret, extend)
	case .Right:
		caret := next_input_character(console, console.input_caret)
		if by_word {caret = next_word(console)}
		if !extend && selection_start != selection_end {caret = selection_end}
		set_input_caret(console, caret, extend)
	case .Home:
		set_input_caret(console, 0, extend)
	case .End:
		set_input_caret(console, console.input_len, extend)
	case .Previous_History:
		previous_history(console)
	case .Next_History:
		next_history(console)
	case .Select_All:
		set_input_caret(console, 0)
		set_input_caret(console, console.input_len, true)
	}
	return console.edit_revision != old_revision
}

// insert_text replaces the selection or inserts at the caret. Invalid/control
// text and oversized replacements are rejected atomically, including pastes.
insert_text :: proc(console: ^Console, text: string) -> bool {
	if len(text) == 0 {return false}
	start, end := input_selection(console)
	if len(text) > Max_Input_Length - console.input_len + (end - start) {return false}
	if !utf8.valid_string(text) {return false}
	for character in text {
		if !unicode.is_graphic(character) {return false}
	}
	new_length := console.input_len - (end - start) + len(text)
	// Scratch also supports text borrowed from the current input buffer.
	replacement: [Max_Input_Length]u8
	copy(replacement[:start], console.input[:start])
	copy(replacement[start:start + len(text)], text)
	copy(replacement[start + len(text):new_length], console.input[end:console.input_len])
	console.input = replacement
	console.input_len = new_length
	console.input_caret = start + len(text)
	console.input_anchor = console.input_caret
	console.selection_target = .Input
	console.edit_revision += 1
	return true
}

insert_character :: proc(console: ^Console, character: rune) -> bool {
	if !unicode.is_graphic(character) {return false}
	encoded, length := utf8.encode_rune(character)
	return insert_text(console, string(encoded[:length]))
}

// These are the same clipboard paths used by Ctrl+X/V. Runtime validators can
// exercise their OS clipboard behavior directly without keyboard focus.
cut_selection :: proc(console: ^Console) -> bool {
	start, end := input_selection(console)
	if !copy_selection(console) {return false}
	if console.selection_target == .Input && start != end {edit(console, .Backspace)}
	return true
}

paste_clipboard :: proc(console: ^Console) -> bool {
	set_input_caret(console, console.input_caret, true)
	clipboard := rl.GetClipboardText()
	if clipboard == nil {return false}
	text := string(clipboard)
	if len(text) == 0 {return false}
	if insert_text(console, text) {return true}
	warning(console, "Paste requires one visible line that fits the 256-byte command limit.")
	return false
}

remove_input :: proc(console: ^Console, start, end: int) {
	if start >= end {return}
	for index in end ..< console.input_len {
		console.input[start + index - end] = console.input[index]
	}
	console.input_len -= end - start
	console.input_caret = start
	console.input_anchor = start
	console.edit_revision += 1
}

input_boundary :: proc(console: ^Console, position: int) -> int {
	index := clamp(position, 0, console.input_len)
	for index > 0 && index < console.input_len && !utf8.rune_start(console.input[index]) {index -= 1}
	return index
}

previous_input_character :: proc(console: ^Console, position: int) -> int {
	if position <= 0 {return 0}
	return input_boundary(console, position - 1)
}

next_input_character :: proc(console: ^Console, position: int) -> int {
	if position >= console.input_len {return console.input_len}
	_, size := utf8.decode_rune(string(console.input[position:console.input_len]))
	return min(console.input_len, position + max(1, size))
}

previous_word :: proc(console: ^Console) -> int {
	index := console.input_caret
	for index > 0 {
		previous := previous_input_character(console, index)
		character, _ := utf8.decode_rune(string(console.input[previous:index]))
		if !unicode.is_space(character) {break}
		index = previous
	}
	for index > 0 {
		previous := previous_input_character(console, index)
		character, _ := utf8.decode_rune(string(console.input[previous:index]))
		if unicode.is_space(character) {break}
		index = previous
	}
	return index
}

next_word :: proc(console: ^Console) -> int {
	index := console.input_caret
	for index < console.input_len {
		character, _ := utf8.decode_rune(string(console.input[index:console.input_len]))
		if unicode.is_space(character) {break}
		index = next_input_character(console, index)
	}
	for index < console.input_len {
		character, _ := utf8.decode_rune(string(console.input[index:console.input_len]))
		if !unicode.is_space(character) {break}
		index = next_input_character(console, index)
	}
	return index
}

make_history_line :: proc(message: string) -> History_Line {
	result: History_Line
	result.len = min(len(message), Max_Input_Length)
	copy(result.text[:result.len], message[:result.len])
	return result
}

key_pressed_or_repeated :: proc(key: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)
}
