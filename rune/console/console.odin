package console

import "core:strings"
import "core:encoding/json"
import rl "vendor:raylib"

// Console is a small runtime developer console. It intentionally owns no game
// state: games register commands whose handlers perform game-specific work.
Max_Log_Lines :: 64
Max_Line_Length :: 192
Max_Line_Highlights :: 64
Max_Input_Length :: 256
Max_History :: 16
Max_Commands :: 64
Max_Name_Length :: 48

Log_Level :: enum {
	Info,
	Warning,
	Error,
}

Log_Line :: struct {
	sequence: u64,
	level: Log_Level,
	text:  [Max_Line_Length]u8,
	len:   int,
	spans: [Max_Line_Highlights]Log_Span,
	span_count: int,
	continues_previous: bool,
}

Command_Proc :: #type proc(console: ^Console, arguments: string)

Command :: struct {
	name:            [Max_Name_Length]u8,
	name_len:        int,
	description:     [Max_Line_Length]u8,
	description_len: int,
	handler:         Command_Proc,
}

Console :: struct {
	is_open:       bool,
	lines:         [Max_Log_Lines]Log_Line,
	line_start:    int,
	line_count:    int,
	input:         [Max_Input_Length]u8,
	input_len:     int,
	input_caret:   int,
	input_anchor:  int,
	selection_target: Selection_Target,
	edit_revision: u64,
	renderer:      Renderer,
	// Wrapped rows above the newest output. Zero follows incoming messages.
	scroll_offset: int,
	scroll_anchor_sequence: u64,
	scroll_anchor_byte: int,
	output_selection: Output_Selection,
	history:       [Max_History]History_Line,
	history_count: int,
	history_index: int,
	history_draft: [Max_Input_Length]u8,
	history_draft_len: int,
	history_draft_caret: int,
	commands:      [Max_Commands]Command,
	command_count: int,
	log_sequence:  u64,
	error_count:   u64,
	capture:       Capture_Request,
	remote:        Remote_Console,
	user_data:     rawptr,
	// Borrow frame scratch until the reply is written; never retain across frames.
	result_data:   json.Value,
	defer_reply:   bool,
	frame_metadata: Frame_Metadata,
}

init :: proc() -> Console {
	result := Console {
		history_index = -1,
	}
	register(&result, "clear", "Clear console output.", clear_command)
	register(&result, "help", "List registered console commands.", help_command)
	register(&result, "capture", "Save this frame: capture [path.png] (without console overlay).", capture_command)
	register(&result, "logs", "Read logs after a sequence: logs [since-sequence].", logs_command)
	log(&result, .Info, "Rune console ready. Press ` to toggle; type help for commands.")
	return result
}

// register adds a command by name. Names are case-sensitive and must be
// unique. Command data is copied, so caller-provided strings need not persist.
register :: proc(console: ^Console, name, description: string, handler: Command_Proc) -> bool {
	if len(name) == 0 ||
	   len(name) > Max_Name_Length ||
	   len(description) > Max_Line_Length ||
	   handler == nil ||
	   console.command_count >= Max_Commands {
		return false
	}
	for index in 0 ..< console.command_count {
		if command_name(&console.commands[index]) == name {return false}
	}
	command := &console.commands[console.command_count]
	copy(command.name[:], name)
	command.name_len = len(name)
	copy(command.description[:], description)
	command.description_len = len(description)
	command.handler = handler
	console.command_count += 1
	return true
}

log :: proc(console: ^Console, level: Log_Level, message: string) {
	console.log_sequence += 1
	if level == .Error {console.error_count += 1}
	index := (console.line_start + console.line_count) % Max_Log_Lines
	if console.line_count == Max_Log_Lines {
		console.line_start = (console.line_start + 1) % Max_Log_Lines
	} else {
		console.line_count += 1
	}
	line := &console.lines[index]
	line^ = {}
	line.sequence = console.log_sequence
	line.level = level
	line.len = result_chunk_end(message, 0)
	copy(line.text[:line.len], message[:line.len])
}

log_parts :: proc(console: ^Console, level: Log_Level, parts: []string) {
	buffer: [Max_Line_Length]u8
	length := 0
	for part in parts {
		if length >= Max_Line_Length {break}
		count := result_chunk_end(part, 0, Max_Line_Length - length)
		copy(buffer[length:length + count], part[:count])
		length += count
		if count < len(part) {break}
	}
	log(console, level, string(buffer[:length]))
}

info :: proc(console: ^Console, message: string) {log(console, .Info, message)}
warning :: proc(console: ^Console, message: string) {log(console, .Warning, message)}
error :: proc(console: ^Console, message: string) {log(console, .Error, message)}

// update handles console-only keyboard input. It runs before game systems;
// systems that need exclusive input can query is_open and skip their controls.
update :: proc(console: ^Console) {
	poll_remote(console, rl.GetTime())
	if rl.IsKeyPressed(.GRAVE) {
		console.is_open = !console.is_open
		console.edit_revision += 1
		console.renderer.dragging_scrollbar = false
		console.renderer.dragging_text = false
		console.renderer.wheel_remainder = 0
		discard_characters()
		return
	}
	if !console.is_open {return}

	if rl.IsKeyPressed(.ESCAPE) {
		console.is_open = false
		console.renderer.dragging_scrollbar = false
		console.renderer.dragging_text = false
		return
	}
	update_view(console)
	by_word := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	extend := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	if by_word && rl.IsKeyPressed(.A) {select_all(console)}
	if by_word && rl.IsKeyPressed(.C) {copy_selection(console)}
	if by_word && rl.IsKeyPressed(.X) {cut_selection(console)}
	if by_word && rl.IsKeyPressed(.V) {paste_clipboard(console)}
	if key_pressed_or_repeated(.BACKSPACE) {edit(console, .Backspace, by_word)}
	if key_pressed_or_repeated(.DELETE) {edit(console, .Delete, by_word)}
	if key_pressed_or_repeated(.LEFT) {edit(console, .Left, by_word, extend)}
	if key_pressed_or_repeated(.RIGHT) {edit(console, .Right, by_word, extend)}
	if rl.IsKeyPressed(.HOME) {edit(console, .Home, false, extend)}
	if rl.IsKeyPressed(.END) {edit(console, .End, false, extend)}
	if key_pressed_or_repeated(.UP) {edit(console, .Previous_History)}
	if key_pressed_or_repeated(.DOWN) {edit(console, .Next_History)}

	for character := rl.GetCharPressed(); character > 0; character = rl.GetCharPressed() {
		if !by_word {insert_character(console, rune(character))}
	}
	if rl.IsKeyPressed(.ENTER) {submit(console)}
}

// submit executes the current input line. It is public so headless validation
// tools can exercise registered commands without a raylib window. Pending
// commands keep the draft intact; navigation and editing remain available.
submit :: proc(console: ^Console) {
	if console.remote.result_len > 0 || console.defer_reply {return}
	buffer := console.input
	line := string(buffer[:console.input_len])
	console.input_len = 0
	console.input_caret = 0
	console.input_anchor = 0
	console.selection_target = .Input
	console.edit_revision += 1
	console.history_index = -1
	console.history_draft_len = 0
	console.history_draft_caret = 0
	execute(console, line)
}

// execute dispatches the same commands as interactive input, without changing
// the line the user is currently typing. Arguments are borrowed for this call.
execute :: proc(console: ^Console, command_line: string) -> bool {
	if console.defer_reply {
		warning(console, "A step/profile command is still running.")
		return false
	}
	console.result_data = {}
	if len(command_line) > Max_Input_Length {
		error(console, "Command exceeds 256 bytes.")
		return false
	}
	for character in command_line {
		if character == '\n' || character == '\r' || character == 0 {
			error(console, "Expected one command line.")
			return false
		}
	}
	line := strings.trim_space(command_line)
	if len(line) == 0 {return false}
	log_parts(console, .Info, {"> ", line})
	add_history(console, line)

	name_end := 0
	for name_end < len(line) && line[name_end] != ' ' && line[name_end] != '\t' {name_end += 1}
	name := line[:name_end]
	arguments := strings.trim_space(line[name_end:])
	for index in 0 ..< console.command_count {
		command := &console.commands[index]
		if command_name(command) == name {
			command.handler(console, arguments)
			return true
		}
	}
	log_parts(console, .Error, {"Unknown command: ", name})
	return false
}

draw :: proc(console: ^Console) {
	draw_view(console)
}

is_open :: proc(console: ^Console) -> bool {return console.is_open}

clear_command :: proc(console: ^Console, arguments: string) {
	console.line_start = 0
	console.line_count = 0
	console.scroll_offset = 0
	console.scroll_anchor_sequence = 0
	console.output_selection = {}
}

help_command :: proc(console: ^Console, arguments: string) {
	for index in 0 ..< console.command_count {
		command := console.commands[index]
		log_parts(console, .Info, {command_name(&command), " - ", command_description(&command)})
	}
}

add_history :: proc(console: ^Console, line: string) {
	if console.history_count < Max_History {
		console.history[console.history_count] = make_history_line(line)
		console.history_count += 1
		return
	}
	copy(console.history[:Max_History - 1], console.history[1:])
	console.history[Max_History - 1] = make_history_line(line)
	// Remote commands add history without disturbing the recalled input. Keep
	// its index attached to the same entry while the oldest command is evicted.
	if console.history_index > 0 {
		console.history_index -= 1
	} else if console.history_index == 0 {
		console.history_index = History_Evicted_Index
	}
}

previous_history :: proc(console: ^Console) {
	if console.history_count == 0 {return}
	if console.history_index == History_Evicted_Index {return}
	if console.history_index < 0 {
		console.history_draft = console.input
		console.history_draft_len = console.input_len
		console.history_draft_caret = console.input_caret
		console.history_index = console.history_count - 1
	} else if console.history_index > 0 {
		console.history_index -= 1
	} else {
		return
	}
	copy_input(console, &console.history[console.history_index])
}

next_history :: proc(console: ^Console) {
	if console.history_index == History_Evicted_Index {
		console.history_index = 0
		copy_input(console, &console.history[0])
		return
	}
	if console.history_index < 0 {return}
	if console.history_index >= console.history_count - 1 {
		console.history_index = -1
		console.input = console.history_draft
		console.input_len = console.history_draft_len
		console.input_caret = console.history_draft_caret
		console.input_anchor = console.input_caret
		console.selection_target = .Input
		console.edit_revision += 1
		return
	}
	console.history_index += 1
	copy_input(console, &console.history[console.history_index])
}

copy_input :: proc(console: ^Console, line: ^History_Line) {
	console.input_len = line.len
	console.input_caret = line.len
	console.input_anchor = line.len
	console.selection_target = .Input
	copy(console.input[:console.input_len], line.text[:line.len])
	console.edit_revision += 1
}

make_line :: proc(level: Log_Level, message: string) -> Log_Line {
	result := Log_Line {
		level = level,
	}
	result.len = result_chunk_end(message, 0)
	copy(result.text[:result.len], message[:result.len])
	return result
}

command_name :: proc(command: ^Command) -> string {return string(command.name[:command.name_len])}
command_description :: proc(command: ^Command) -> string {return string(
		command.description[:command.description_len],
	)}

color_for_level :: proc(level: Log_Level) -> rl.Color {
	switch level {
	case .Info:
		return Text_Color
	case .Warning:
		return {245, 197, 106, 255}
	case .Error:
		return {255, 134, 145, 255}
	}
	return Text_Color
}

discard_characters :: proc() {
	for character := rl.GetCharPressed(); character > 0; character = rl.GetCharPressed() {}
}
