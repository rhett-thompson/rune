package console

import "core:encoding/json"
import "core:testing"

completion_test_handler :: proc(dev: ^Console, arguments: string) {}

@(test)
completion_fills_unique_names_without_appending_a_space :: proc(t: ^testing.T) {
	dev := init()
	insert_text(&dev, "he")
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "help")
	testing.expect(t, dev.input_caret == 4 && dev.input_anchor == 4)
	revision := dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, !complete(&dev, true))
	testing.expect(t, input_text(&dev) == "help" && dev.edit_revision == revision)
}

@(test)
completion_cycles_alphabetically_from_the_original_prefix :: proc(t: ^testing.T) {
	dev := init()
	register(&dev, "clock", "", completion_test_handler)
	register(&dev, "camera", "", completion_test_handler)
	insert_text(&dev, "c")
	for expected in ([5]string{"camera", "capture", "clear", "clock", "camera"}) {
		testing.expect(t, complete(&dev))
		testing.expect(t, input_text(&dev) == expected)
	}
	testing.expect(t, complete(&dev, true))
	testing.expect(t, input_text(&dev) == "clock")
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "camera")

	reverse_dev := init()
	insert_text(&reverse_dev, "c")
	testing.expect(t, complete(&reverse_dev, true))
	testing.expect(t, input_text(&reverse_dev) == "clear")
	testing.expect(t, complete(&reverse_dev, true))
	testing.expect(t, input_text(&reverse_dev) == "capture")
	testing.expect(t, complete(&reverse_dev, true))
	testing.expect(t, input_text(&reverse_dev) == "clear")
}

@(test)
completion_accepts_an_empty_prefix_and_matches_case_sensitively :: proc(t: ^testing.T) {
	dev := init()
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "capture")
	testing.expect(t, complete(&dev, true))
	testing.expect(t, input_text(&dev) == "logs")

	dev = init()
	register(&dev, "Help", "", completion_test_handler)
	insert_text(&dev, "H")
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "Help")
}

@(test)
completion_replaces_the_command_token_and_preserves_utf8_arguments :: proc(t: ^testing.T) {
	dev := init()
	register(&dev, "éclair", "", completion_test_handler)
	register(&dev, "écoute", "", completion_test_handler)
	leading := "\u2003 "
	insert_text(&dev, "\u2003 éunfinished  argument🙂")
	set_input_caret(&dev, len(leading) + len("é"))
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "\u2003 éclair  argument🙂")
	testing.expect(t, dev.input_caret == len(leading) + len("éclair"))
	testing.expect(t, dev.input_anchor == dev.input_caret)
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "\u2003 écoute  argument🙂")
	testing.expect(t, dev.input_caret == len(leading) + len("écoute"))
}

@(test)
completion_leaves_arguments_selections_and_output_focus_untouched :: proc(t: ^testing.T) {
	dev := init()
	insert_text(&dev, "he argument")
	revision := dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "he argument" && dev.edit_revision == revision)

	set_input_caret(&dev, 0)
	set_input_caret(&dev, 2, true)
	revision = dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "he argument" && dev.edit_revision == revision)
	testing.expect(t, dev.input_anchor == 0 && dev.input_caret == 2)

	set_input_caret(&dev, 2)
	dev.selection_target = .Output
	revision = dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "he argument" && dev.edit_revision == revision)
	testing.expect(t, dev.selection_target == .Output)

	dev.selection_target = .Input
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "help argument")
}

@(test)
completion_restarts_after_caret_edits_history_or_registration :: proc(t: ^testing.T) {
	dev := init()
	insert_text(&dev, "c")
	complete(&dev)
	complete(&dev)
	testing.expect(t, input_text(&dev) == "clear")
	edit(&dev, .Left)
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "clear" && dev.input_caret == 5)
	testing.expect(t, !complete(&dev), "moving the caret must discard the old c prefix")
	edit(&dev, .Select_All)
	insert_text(&dev, "he")
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "help")

	dev = init()
	execute(&dev, "help")
	insert_text(&dev, "c")
	complete(&dev)
	edit(&dev, .Previous_History)
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "help")
	edit(&dev, .Next_History)
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "capture")

	dev = init()
	insert_text(&dev, "c")
	complete(&dev)
	register(&dev, "carpet", "", completion_test_handler)
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "capture", "a changed registry starts from the current command")
}

@(test)
completion_skips_names_that_do_not_fit_without_damaging_input :: proc(t: ^testing.T) {
	dev := init()
	full: [Max_Input_Length]u8
	for &byte in full {byte = 'x'}
	full[0] = 'c'
	full[1] = ' '
	insert_text(&dev, string(full[:]))
	set_input_caret(&dev, 1)
	revision := dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == string(full[:]))
	testing.expect(t, dev.input_caret == 1 && dev.input_anchor == 1 && dev.edit_revision == revision)

	register(&dev, "c", "", completion_test_handler)
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == string(full[:]) && dev.edit_revision == revision)

	// The shorter name fits exactly; the longer name would exceed the limit.
	full[0] = 'q'
	edit(&dev, .Select_All)
	insert_text(&dev, string(full[:Max_Input_Length - 1]))
	set_input_caret(&dev, 1)
	register(&dev, "qaa", "", completion_test_handler)
	register(&dev, "qz", "", completion_test_handler)
	testing.expect(t, complete(&dev))
	testing.expect(t, dev.input_len == Max_Input_Length)
	testing.expect(t, string(dev.input[:3]) == "qz ")
	testing.expect(t, !complete(&dev, true))
}

@(test)
completion_ignores_invalid_registered_names_and_unmatched_prefixes :: proc(t: ^testing.T) {
	dev := init()
	for name in ([5]string{"z bad", "z\tbad", "z\u2003bad", "z\xc3", "z\n"}) {
		testing.expect(t, register(&dev, name, "", completion_test_handler))
	}
	insert_text(&dev, "z")
	revision := dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "z" && dev.edit_revision == revision)
	register(&dev, "zeta", "", completion_test_handler)
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "zeta")

	edit(&dev, .Select_All)
	insert_text(&dev, "missing")
	revision = dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "missing" && dev.edit_revision == revision)
}

@(test)
completion_preserves_history_and_pending_command_results :: proc(t: ^testing.T) {
	dev := init()
	execute(&dev, "clear")
	insert_text(&dev, "draft")
	edit(&dev, .Previous_History)
	set_input_caret(&dev, 1)
	dev.defer_reply = true
	dev.remote.result_len = 1
	dev.result_data = json.Integer(42)
	sequence := dev.log_sequence
	line_count := dev.line_count
	history_index := dev.history_index
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "capture")
	testing.expect(t, dev.history_index == history_index && dev.history_count == 1)
	testing.expect(t, string(dev.history[0].text[:dev.history[0].len]) == "clear")
	testing.expect(t, dev.log_sequence == sequence && dev.line_count == line_count)
	result, ok := dev.result_data.(json.Integer)
	testing.expect(t, ok && result == 42 && dev.defer_reply && dev.remote.result_len == 1)
	edit(&dev, .Next_History)
	testing.expect(t, input_text(&dev) == "draft" && dev.input_caret == 5)
}
