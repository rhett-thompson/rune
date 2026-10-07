package console

import "core:testing"
import "core:encoding/json"
import "core:fmt"

input_text :: proc(console: ^Console) -> string {
	return string(console.input[:console.input_len])
}

@(test)
input_edits_at_the_caret_and_deletes_on_each_action :: proc(t: ^testing.T) {
	dev := init()
	testing.expect(t, insert_text(&dev, "echo ac"))
	testing.expect(t, dev.input_caret == 7)
	testing.expect(t, edit(&dev, .Left))
	testing.expect(t, insert_text(&dev, "b"))
	testing.expect(t, input_text(&dev) == "echo abc" && dev.input_caret == 7)
	// One backspace action must erase immediately; another is a held-key repeat.
	testing.expect(t, edit(&dev, .Backspace))
	testing.expect(t, input_text(&dev) == "echo ac" && dev.input_caret == 6)
	testing.expect(t, edit(&dev, .Backspace))
	testing.expect(t, input_text(&dev) == "echo c" && dev.input_caret == 5)
	testing.expect(t, edit(&dev, .Delete))
	testing.expect(t, input_text(&dev) == "echo " && dev.input_caret == 5)
	testing.expect(t, !edit(&dev, .Delete))
	testing.expect(t, edit(&dev, .Home))
	testing.expect(t, !edit(&dev, .Left) && !edit(&dev, .Backspace))
	testing.expect(t, edit(&dev, .End))
	testing.expect(t, !edit(&dev, .Right))
}

@(test)
input_word_actions_follow_command_tokens :: proc(t: ^testing.T) {
	dev := init()
	insert_text(&dev, "set player  Transform.position  [1,2,3]")
	edit(&dev, .Left, true)
	testing.expect(t, dev.input_caret == 32)
	edit(&dev, .Left, true)
	testing.expect(t, dev.input_caret == 12)
	edit(&dev, .Right, true)
	testing.expect(t, dev.input_caret == 32)
	edit(&dev, .Backspace, true)
	testing.expect(t, input_text(&dev) == "set player  [1,2,3]" && dev.input_caret == 12)
	edit(&dev, .Delete, true)
	testing.expect(t, input_text(&dev) == "set player  " && dev.input_caret == 12)
}

@(test)
history_restores_the_unsubmitted_draft_and_its_caret :: proc(t: ^testing.T) {
	dev := init()
	execute(&dev, "clear")
	execute(&dev, "help")
	insert_text(&dev, "unfinished")
	edit(&dev, .Left)
	edit(&dev, .Left)
	testing.expect(t, edit(&dev, .Previous_History))
	testing.expect(t, input_text(&dev) == "help" && dev.input_caret == 4)
	testing.expect(t, edit(&dev, .Previous_History))
	testing.expect(t, input_text(&dev) == "clear" && dev.input_caret == 5)
	testing.expect(t, !edit(&dev, .Previous_History))
	edit(&dev, .Next_History)
	edit(&dev, .Next_History)
	testing.expect(t, input_text(&dev) == "unfinished" && dev.input_caret == 8)
	testing.expect(t, dev.history_index == -1 && !edit(&dev, .Next_History))
	// Editing a recalled copy must never alter the stored command.
	edit(&dev, .Previous_History)
	edit(&dev, .Backspace)
	edit(&dev, .Next_History)
	edit(&dev, .Previous_History)
	testing.expect(t, input_text(&dev) == "help")
}

@(test)
input_and_history_preserve_the_full_command_limit :: proc(t: ^testing.T) {
	dev := init()
	full: [Max_Input_Length]u8
	for &byte in full {byte = 'x'}
	testing.expect(t, insert_text(&dev, string(full[:])))
	testing.expect(t, !insert_text(&dev, "y"))
	testing.expect(t, dev.input_len == Max_Input_Length && dev.input_caret == Max_Input_Length)
	submit(&dev)
	testing.expect(t, dev.input_len == 0 && dev.input_caret == 0 && dev.history_index == -1)
	edit(&dev, .Previous_History)
	testing.expect(t, input_text(&dev) == string(full[:]) && dev.input_caret == Max_Input_Length)
	edit(&dev, .Next_History)
	testing.expect(t, dev.input_len == 0 && dev.input_caret == 0)
	testing.expect(t, !insert_text(&dev, "bad\nline"))
	testing.expect(t, !insert_text(&dev, "bad\tline"))
	testing.expect(t, dev.input_len == 0)
}

@(test)
submit_dispatches_the_edited_line_and_clears_the_editor :: proc(t: ^testing.T) {
	dev := init()
	insert_text(&dev, "cler")
	edit(&dev, .Left)
	insert_text(&dev, "a")
	submit(&dev)
	testing.expect(t, dev.line_count == 0, "edited clear command should run")
	testing.expect(t, dev.input_len == 0 && dev.input_caret == 0)
	testing.expect(t, dev.history_draft_len == 0 && dev.history_index == -1)
	testing.expect(t, string(dev.history[0].text[:dev.history[0].len]) == "clear")
}

@(test)
pending_commands_allow_edits_and_preserve_draft_on_submit :: proc(t: ^testing.T) {
	dev := init()
	insert_text(&dev, "clear")
	dev.defer_reply = true
	dev.result_data = json.Integer(42)
	log_sequence := dev.log_sequence
	edit(&dev, .Left)
	insert_text(&dev, "x")
	edit(&dev, .Backspace)
	caret := dev.input_caret
	revision := dev.edit_revision
	submit(&dev)
	testing.expect(t, input_text(&dev) == "clear" && dev.input_caret == caret)
	testing.expect(t, dev.edit_revision == revision && dev.history_count == 0)
	testing.expect(t, dev.log_sequence == log_sequence)
	result, ok := dev.result_data.(json.Integer)
	testing.expect(t, ok && result == 42, "pending command result must survive interactive Enter")
	dev.defer_reply = false
	dev.remote.result_len = 1
	submit(&dev)
	testing.expect(t, input_text(&dev) == "clear" && dev.edit_revision == revision)
	result, ok = dev.result_data.(json.Integer)
	testing.expect(t, ok && result == 42)
	dev.remote.result_len = 0
	submit(&dev)
	testing.expect(t, dev.input_len == 0 && dev.history_count == 1 && dev.line_count == 0)
}

@(test)
remote_history_append_preserves_selection_and_an_evicted_entry_successor :: proc(t: ^testing.T) {
	dev := init()
	for index in 0 ..< Max_History {execute(&dev, fmt.tprintf("clear %02d", index))}
	insert_text(&dev, "draft")
	edit(&dev, .Previous_History)
	testing.expect(t, input_text(&dev) == "clear 15")
	execute(&dev, "clear 16")
	testing.expect(t, input_text(&dev) == "clear 15" && dev.history_index == 14)
	edit(&dev, .Previous_History)
	testing.expect(t, input_text(&dev) == "clear 14", "Up must visit the older entry after a remote append")
	edit(&dev, .Next_History)
	edit(&dev, .Next_History)
	testing.expect(t, input_text(&dev) == "clear 16")
	edit(&dev, .Next_History)
	testing.expect(t, input_text(&dev) == "draft")
	for _ in 0 ..< Max_History {edit(&dev, .Previous_History)}
	testing.expect(t, input_text(&dev) == "clear 01" && dev.history_index == 0)
	execute(&dev, "clear 17")
	testing.expect(t, input_text(&dev) == "clear 01" && !edit(&dev, .Previous_History))
	edit(&dev, .Next_History)
	testing.expect(t, input_text(&dev) == "clear 02", "Down should not skip the successor of an evicted entry")
	for _ in 0 ..< Max_History {edit(&dev, .Next_History)}
	testing.expect(t, input_text(&dev) == "draft" && dev.input_caret == 5)
}

@(test)
shift_selects_and_plain_arrows_collapse_to_selection_edges :: proc(t: ^testing.T) {
	dev := init()
	insert_text(&dev, "inspect player")
	edit(&dev, .Left, false, true)
	edit(&dev, .Left, false, true)
	start, end := input_selection(&dev)
	testing.expect(t, start == 12 && end == 14 && dev.input_anchor == 14)
	edit(&dev, .Left)
	testing.expect(t, dev.input_caret == 12 && dev.input_anchor == 12)
	edit(&dev, .Home, false, true)
	start, end = input_selection(&dev)
	testing.expect(t, start == 0 && end == 12)
	edit(&dev, .Right)
	testing.expect(t, dev.input_caret == 12 && dev.input_anchor == 12)
	edit(&dev, .End, false, true)
	testing.expect(t, insert_text(&dev, "XYZ"))
	testing.expect(t, input_text(&dev) == "inspect playXYZ" && dev.input_caret == 15)
	testing.expect(t, dev.input_anchor == dev.input_caret)
}

@(test)
selected_backspace_and_delete_remove_the_range_only :: proc(t: ^testing.T) {
	actions := [2]Edit_Action{.Backspace, .Delete}
	for action in actions {
		dev := init()
		insert_text(&dev, "echo player tail")
		set_input_caret(&dev, 5)
		set_input_caret(&dev, 12, true)
		testing.expect(t, edit(&dev, action))
		testing.expect(t, input_text(&dev) == "echo tail")
		testing.expect(t, dev.input_caret == 5 && dev.input_anchor == 5)
	}
}

@(test)
unicode_input_moves_and_deletes_at_complete_codepoint_boundaries :: proc(t: ^testing.T) {
	dev := init()
	testing.expect(t, insert_text(&dev, "Aé界🙂Z"))
	testing.expect(t, dev.input_len == 11)
	left_positions := [5]int{10, 6, 3, 1, 0}
	for expected in left_positions {
		edit(&dev, .Left)
		testing.expect(t, dev.input_caret == expected && dev.input_anchor == expected)
	}
	right_positions := [5]int{1, 3, 6, 10, 11}
	for expected in right_positions {
		edit(&dev, .Right)
		testing.expect(t, dev.input_caret == expected && dev.input_anchor == expected)
	}
	set_input_caret(&dev, 4)
	testing.expect(t, dev.input_caret == 3, "positions inside UTF-8 must snap to the codepoint start")
	edit(&dev, .Delete)
	testing.expect(t, input_text(&dev) == "Aé🙂Z")
	edit(&dev, .Backspace)
	testing.expect(t, input_text(&dev) == "A🙂Z")
	testing.expect(t, insert_character(&dev, '界'))
	testing.expect(t, input_text(&dev) == "A界🙂Z")
	testing.expect(t, !insert_character(&dev, '\n'))
}

@(test)
paste_replacement_checks_utf8_controls_and_byte_capacity_atomically :: proc(t: ^testing.T) {
	dev := init()
	full: [Max_Input_Length]u8
	for &byte in full {byte = 'x'}
	insert_text(&dev, string(full[:]))
	set_input_caret(&dev, 10)
	set_input_caret(&dev, 14, true)
	revision := dev.edit_revision
	testing.expect(t, !insert_text(&dev, "12345"))
	testing.expect(t, !insert_text(&dev, "\xc3"))
	testing.expect(t, !insert_text(&dev, "one\n"))
	testing.expect(t, !insert_text(&dev, "\u2028"))
	testing.expect(t, !insert_text(&dev, "\u0000"))
	testing.expect(t, dev.edit_revision == revision && input_text(&dev) == string(full[:]))
	start, end := input_selection(&dev)
	testing.expect(t, start == 10 && end == 14)
	testing.expect(t, insert_text(&dev, "éé"))
	testing.expect(t, dev.input_len == Max_Input_Length && dev.input_caret == 14 && dev.input_anchor == 14)
	testing.expect(t, string(dev.input[10:14]) == "éé")
	edit(&dev, .Left, false, true)
	testing.expect(t, insert_text(&dev, "a"))
	testing.expect(t, dev.input_len == Max_Input_Length - 1 && string(dev.input[10:13]) == "éa")
}

@(test)
word_selection_focuses_input_and_history_resets_selection :: proc(t: ^testing.T) {
	dev := init()
	execute(&dev, "clear")
	insert_text(&dev, "inspect @player-1 Transform.position")
	dev.selection_target = .Output
	select_input_word(&dev, 12)
	start, end := input_selection(&dev)
	testing.expect(t, dev.selection_target == .Input && string(dev.input[start:end]) == "@player-1")
	edit(&dev, .Previous_History)
	testing.expect(t, input_text(&dev) == "clear" && dev.input_anchor == dev.input_caret)
	edit(&dev, .Next_History)
	testing.expect(t, input_text(&dev) == "inspect @player-1 Transform.position")
	testing.expect(t, dev.input_anchor == dev.input_caret)
	edit(&dev, .Select_All)
	testing.expect(t, insert_text(&dev, "clear"))
	submit(&dev)
	testing.expect(t, dev.input_anchor == 0 && dev.input_caret == 0 && dev.selection_target == .Input)
}

@(test)
input_insertion_can_borrow_its_own_buffer_and_navigation_restores_focus :: proc(t: ^testing.T) {
	dev := init()
	insert_text(&dev, "echo ")
	testing.expect(t, insert_text(&dev, input_text(&dev)))
	testing.expect(t, input_text(&dev) == "echo echo ")
	dev.selection_target = .Output
	edit(&dev, .Left)
	testing.expect(t, dev.selection_target == .Input && dev.input_caret == 9 && dev.input_anchor == 9)
}
