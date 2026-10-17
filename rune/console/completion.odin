package console

import "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// All strings borrow the current input or frame scratch for this call only.
// arguments contains decoded tokens before the active argument, excluding it.
Completion_Request :: struct {
	command: string,
	arguments: []string,
	argument_index: int,
	prefix: string,
}

// Append raw argument values to candidates (allocated in frame scratch).
// Borrowed strings are consumed during the query; no candidate is retained.
// Callbacks are read-only and can run while refreshing the suggestion view.
// The console filters by prefix, sorts while cycling and quotes when needed.
Completion_Proc :: #type proc(console: ^Console, request: Completion_Request, candidates: ^[dynamic]string)

// Only owned bytes survive a completion call: candidate sources may change or
// disappear between frames, including when the active scene World is replaced.
Completion_State :: struct {
	active: bool,
	browsing: bool,
	dismissed: bool,
	prefix: [Max_Input_Length]u8,
	prefix_len: int,
	current: [Max_Input_Length]u8,
	current_len: int,
	command_count: int,
	edit_revision: u64,
}

Completion_Option :: struct {
	value: string, // Raw command name or argument value.
	text: string, // Token inserted into the editor, quoted when needed.
}

// Temporary view of current matches. All strings and options borrow the
// console or frame scratch; do not retain them across edits or frames.
Completion_Matches :: struct {
	options: []Completion_Option,
	selected: int,
	start, end: int,
	request: Completion_Request,
	is_command, cycling, valid: bool,
}

// Query the same valid, fitting matches used by Tab without changing editor,
// history or cycling state. Providers must be read-only: the view also queries
// them while the user types. Empty command input includes all command names;
// the renderer decides when the suggestion panel should be visible.
completion_matches :: proc(console: ^Console) -> (result: Completion_Matches) {
	result.selected = -1
	caret, anchor := input_selection(console)
	if console.selection_target != .Input || caret != anchor {return}
	line := string(console.input[:console.input_len])
	start, end, request, is_command, valid := completion_context(line, caret)
	if !valid {return}
	state := &console.completion
	cycling := state.active && state.edit_revision == console.edit_revision && state.command_count == console.command_count
	if cycling {request.prefix = string(state.prefix[:state.prefix_len])}
	result.start, result.end = start, end
	result.request = request
	result.is_command, result.cycling, result.valid = is_command, cycling, true
	candidates := make([dynamic]string, context.temp_allocator)
	if is_command {
		for index in 0 ..< console.command_count {append(&candidates, command_name(&console.commands[index]))}
	} else {
		for index in 0 ..< console.command_count {
			command := &console.commands[index]
			if command_name(command) != request.command {continue}
			if command.completion != nil {command.completion(console, request, &candidates)}
			break
		}
	}
	options := make([dynamic]Completion_Option, context.temp_allocator)
	capacity := Max_Input_Length - console.input_len + end - start
	for name in candidates {
		if len(name) > Max_Input_Length || !strings.has_prefix(name, request.prefix) ||
		   !completion_value_valid(name, is_command) {continue}
		encoded := name if is_command else encode_argument(name)
		if len(encoded) == 0 || len(encoded) > capacity {continue}
		append(&options, Completion_Option{name, encoded})
	}
	slice.sort_by(options[:], proc(a, b: Completion_Option) -> bool {return a.value < b.value})
	count := 0
	for option in options {
		if count > 0 && options[count-1].value == option.value {continue}
		options[count] = option
		count += 1
	}
	result.options = options[:count]
	if count > 0 {
		result.selected = 0
		if cycling {
			current := string(state.current[:state.current_len])
			for option, index in result.options {
				if option.value == current {result.selected = index; break}
			}
		}
	}
	return
}

// complete cycles command names or command-specific arguments alphabetically
// (backwards for Shift+Tab). It replaces only the token containing the caret,
// preserving the rest of the line. Editing/caret/history changes restart the
// prefix. Like edit, it is headless and returns whether input/caret changed.
complete :: proc(console: ^Console, reverse := false) -> bool {
	matches := completion_matches(console)
	if !matches.valid {console.completion = {}; return false}
	// A temporarily empty live source must not replace the original prefix
	// with the last suggestion when entities disappear between Tab presses.
	if len(matches.options) == 0 {
		console.completion = completion_state(console, matches)
		return false
	}
	index := len(matches.options)-1 if reverse else 0
	if matches.cycling && console.completion.browsing {
		index = matches.selected
	} else if matches.cycling {
		current := string(console.completion.current[:console.completion.current_len])
		if reverse {
			for candidate := len(matches.options)-1; candidate >= 0; candidate -= 1 {
				if matches.options[candidate].value < current {index = candidate; break}
			}
		} else {
			for option, candidate in matches.options {
				if option.value > current {index = candidate; break}
			}
		}
	}
	return apply_completion(console, matches, index)
}

completion_state :: proc(console: ^Console, matches: Completion_Matches) -> Completion_State {
	state := console.completion
	if !matches.cycling {
		state = Completion_State{prefix_len = len(matches.request.prefix)}
		copy(state.prefix[:], matches.request.prefix)
	}
	return state
}

apply_completion :: proc(console: ^Console, matches: Completion_Matches, index: int) -> bool {
	state := completion_state(console, matches)
	name, encoded := matches.options[index].value, matches.options[index].text

	// A provider can borrow bytes from the input itself. Own the selected value
	// before replacing that buffer, which can shift its original source range.
	copy(state.current[:], name)
	state.current_len = len(name)
	start, end := matches.start, matches.end
	line := string(console.input[:console.input_len])
	new_caret := start + len(encoded)
	changed := line[start:end] != encoded || console.input_caret != new_caret || console.input_anchor != new_caret
	if changed {
		new_length := console.input_len - (end - start) + len(encoded)
		replacement: [Max_Input_Length]u8
		copy(replacement[:start], console.input[:start])
		copy(replacement[start:new_caret], encoded)
		copy(replacement[new_caret:new_length], console.input[end:console.input_len])
		console.input = replacement
		console.input_len = new_length
		console.input_caret = new_caret
		console.input_anchor = new_caret
		console.edit_revision += 1
	}
	state.active = true
	state.browsing = false
	state.dismissed = false
	state.command_count = console.command_count
	state.edit_revision = console.edit_revision
	console.completion = state
	return changed
}

completion_value_valid :: proc(value: string, is_command: bool) -> bool {
	if len(value) == 0 || !utf8.valid_string(value) {return false}
	for character in value {
		if !unicode.is_graphic(character) || (is_command && unicode.is_space(character)) {return false}
	}
	return true
}

// encode_argument returns a token accepted by take_argument. Simple names
// stay readable; spaces, quotes and backslashes use JSON string escaping.
encode_argument :: proc(value: string) -> string {
	for character in value {
		if unicode.is_space(character) || character == '"' || character == '\\' {
			encoded, err := json.marshal(value, allocator = context.temp_allocator)
			return string(encoded) if err == nil else ""
		}
	}
	return value
}

// take_argument decodes one whitespace-delimited argument or JSON string.
// It borrows unquoted input and uses frame scratch for decoded strings. A
// malformed quoted token remains undecoded so command handlers reject it.
take_argument :: proc(arguments: string) -> (word, rest: string) {
	line := strings.trim_space(arguments)
	if len(line) == 0 {return "", ""}
	end := argument_token_end(line, 0)
	valid: bool
	word, valid = decode_argument(line[:end])
	if !valid {return line, ""}
	return word, strings.trim_space(line[end:])
}

// Quoted tokens can contain whitespace and escaped quotes. An unclosed quote
// extends to the end of the line so Tab can finish a partially typed ID.
argument_token_end :: proc(line: string, start: int) -> int {
	if line[start] != '"' {
		end := start
		for end < len(line) && line[end] != ' ' && line[end] != '\t' {end += 1}
		return end
	}
	escaped := false
	for end := start + 1; end < len(line); end += 1 {
		if escaped {escaped = false; continue}
		if line[end] == '\\' {escaped = true; continue}
		if line[end] == '"' {
			end += 1
			// A closing quote must end a token, rather than accepting "id"junk.
			if end < len(line) {
				character, _ := utf8.decode_rune(line[end:])
				if !unicode.is_space(character) {
					for end < len(line) && line[end] != ' ' && line[end] != '\t' {end += 1}
				}
			}
			return end
		}
	}
	return len(line)
}

// Decode one complete token, rejecting malformed or partially quoted input.
// Unquoted values borrow token; JSON strings use frame scratch.
decode_argument :: proc(token: string) -> (string, bool) {
	if len(token) == 0 || token[0] != '"' {return token, true}
	// Validate the entire literal before unmarshalling. The JSON reader can
	// accept a value followed by junk and truncate malformed Unicode escapes.
	if len(token) < 2 || token[len(token)-1] != '"' || !utf8.valid_string(token) {return "", false}
	for index := 1; index < len(token)-1; index += 1 {
		character := token[index]
		if character == '"' || character < ' ' {return "", false}
		if character != '\\' {continue}
		index += 1
		if index >= len(token)-1 {return "", false}
		switch token[index] {
		case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
		case 'u':
			if index+4 >= len(token)-1 {return "", false}
			for digit in token[index+1:index+5] {
				if !(digit >= '0' && digit <= '9') && !(digit >= 'a' && digit <= 'f') &&
				   !(digit >= 'A' && digit <= 'F') {return "", false}
			}
			index += 4
		case: return "", false
		}
	}
	value: string
	if json.unmarshal(transmute([]u8)token, &value, spec = .JSON, allocator = context.temp_allocator) != nil {return "", false}
	return value, true
}

completion_context :: proc(line: string, caret: int) -> (start, end: int, request: Completion_Request, is_command, valid: bool) {
	start = len(line) - len(strings.trim_left_space(line))
	end = start
	for end < len(line) && line[end] != ' ' && line[end] != '\t' {end += 1}
	if caret < start {return}
	request.command = line[start:end]
	if caret <= end {
		request.prefix = line[start:caret]
		return start, end, request, true, true
	}
	arguments := make([dynamic]string, context.temp_allocator)
	cursor := end
	for {
		for cursor < len(line) {
			character, size := utf8.decode_rune(line[cursor:])
			if !unicode.is_space(character) {break}
			if caret == cursor {break}
			cursor += max(1, size)
		}
		start, end = cursor, cursor
		if cursor < len(line) {
			character, _ := utf8.decode_rune(line[cursor:])
			if !unicode.is_space(character) {end = argument_token_end(line, start)}
		}
		if caret >= start && caret <= end {
			prefix := line[start:caret]
			if len(prefix) > 0 && prefix[0] == '"' {
				decoded, ok := decode_argument(prefix)
				if !ok {decoded, ok = decode_argument(strings.concatenate({prefix, "\""}, context.temp_allocator))}
				if !ok {return}
				prefix = decoded
			}
			request.arguments = arguments[:]
			request.argument_index = len(arguments)
			request.prefix = prefix
			return start, end, request, false, true
		}
		if end <= start {return}
		value, ok := decode_argument(line[start:end])
		if !ok {return}
		append(&arguments, value)
		cursor = end
	}
}
