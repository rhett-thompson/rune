package console

// Arrow navigation owns only the highlighted value, leaving the command,
// caret, history, and pending results intact until the user accepts a match.
navigate_suggestions :: proc(console: ^Console, reverse := false) -> bool {
	return navigate_suggestion_matches(console, view_completion_matches(console), reverse)
}

navigate_suggestion_matches :: proc(console: ^Console, matches: Completion_Matches, reverse: bool) -> bool {
	count := len(matches.options)
	if count == 0 {return false}
	index := (matches.selected + count + (-1 if reverse else 1)) % count
	state := completion_state(console, matches)
	name := matches.options[index].value
	copy(state.current[:], name)
	state.current_len = len(name)
	state.active = true
	state.browsing = true
	state.dismissed = false
	state.command_count = console.command_count
	state.edit_revision = console.edit_revision
	console.completion = state
	return true
}

// An unchanged exact match is still accepted: consume that Enter, dismiss the
// panel, and let the next Enter submit instead of repeatedly accepting it.
accept_suggestion :: proc(console: ^Console) -> bool {
	return accept_suggestion_matches(console, view_completion_matches(console))
}

accept_suggestion_matches :: proc(console: ^Console, matches: Completion_Matches) -> bool {
	if len(matches.options) == 0 {return false}
	apply_completion(console, matches, matches.selected)
	console.completion.active = false
	console.completion.browsing = false
	console.completion.dismissed = true
	return true
}

// These headless entry points share the interactive key routing. The window
// path supplies its actual popup visibility and the same queried matches used
// for layout; tests and custom loops may query the current matches on demand.
input_vertical :: proc(console: ^Console, previous: bool, suggestions_visible := true,
	history_only := false, matches: ^Completion_Matches = nil) -> bool {
	if suggestions_visible && !history_only {
		options := matches^ if matches != nil else view_completion_matches(console)
		if navigate_suggestion_matches(console, options, previous) {return true}
	}
	return edit(console, .Previous_History if previous else .Next_History)
}

input_enter :: proc(console: ^Console, suggestions_visible := true, matches: ^Completion_Matches = nil) {
	if suggestions_visible {
		options := matches^ if matches != nil else view_completion_matches(console)
		if accept_suggestion_matches(console, options) {return}
	}
	submit(console)
}
