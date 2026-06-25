package console

import "core:strings"
import rl "vendor:raylib"

// Console is a small runtime developer console. It intentionally owns no game
// state: games register commands whose handlers perform game-specific work.
Max_Log_Lines    :: 64
Max_Line_Length  :: 192
Max_Input_Length :: 256
Max_History      :: 16
Max_Commands     :: 32
Max_Name_Length  :: 48

Log_Level :: enum { Info, Warning, Error }

Log_Line :: struct {
	level: Log_Level,
	text:  [Max_Line_Length]u8,
	len:   int,
}

Command_Proc :: #type proc(console: ^Console, arguments: string)

Command :: struct {
	name:        [Max_Name_Length]u8,
	name_len:    int,
	description: [Max_Line_Length]u8,
	description_len: int,
	handler:     Command_Proc,
}

Console :: struct {
	is_open:       bool,
	lines:         [Max_Log_Lines]Log_Line,
	line_start:    int,
	line_count:    int,
	input:         [Max_Input_Length]u8,
	input_len:     int,
	history:       [Max_History]Log_Line,
	history_count: int,
	history_index: int,
	commands:      [Max_Commands]Command,
	command_count: int,
}

init :: proc() -> Console {
	result := Console{history_index = -1}
	register(&result, "clear", "Clear console output.", clear_command)
	register(&result, "help", "List registered console commands.", help_command)
	log(&result, .Info, "Rune console ready. Press ` to toggle; type help for commands.")
	return result
}

// register adds a command by name. Names are case-sensitive and must be
// unique. Command data is copied, so caller-provided strings need not persist.
register :: proc(console: ^Console, name, description: string, handler: Command_Proc) -> bool {
	if len(name) == 0 || len(name) > Max_Name_Length || len(description) > Max_Line_Length || handler == nil || console.command_count >= Max_Commands {
		return false
	}
	for index in 0..<console.command_count {
		if command_name(&console.commands[index]) == name { return false }
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
	index := (console.line_start + console.line_count) % Max_Log_Lines
	if console.line_count == Max_Log_Lines {
		console.line_start = (console.line_start + 1) % Max_Log_Lines
	} else {
		console.line_count += 1
	}
	line := &console.lines[index]
	line.level = level
	line.len = min(len(message), Max_Line_Length)
	copy(line.text[:line.len], message[:line.len])
}

log_parts :: proc(console: ^Console, level: Log_Level, parts: []string) {
	buffer: [Max_Line_Length]u8
	length := 0
	for part in parts {
		if length >= Max_Line_Length { break }
		count := min(len(part), Max_Line_Length - length)
		copy(buffer[length:length+count], part[:count])
		length += count
	}
	log(console, level, string(buffer[:length]))
}

info :: proc(console: ^Console, message: string) { log(console, .Info, message) }
warning :: proc(console: ^Console, message: string) { log(console, .Warning, message) }
error :: proc(console: ^Console, message: string) { log(console, .Error, message) }

// update handles console-only keyboard input. It runs before game systems;
// systems that need exclusive input can query is_open and skip their controls.
update :: proc(console: ^Console) {
	if rl.IsKeyPressed(.GRAVE) {
		console.is_open = !console.is_open
		discard_characters()
		return
	}
	if !console.is_open { return }

	if rl.IsKeyPressed(.ESCAPE) {
		console.is_open = false
		return
	}
	if rl.IsKeyPressedRepeat(.BACKSPACE) && console.input_len > 0 {
		console.input_len -= 1
	}
	if rl.IsKeyPressed(.ENTER) {
		submit(console)
		return
	}
	if rl.IsKeyPressedRepeat(.UP) { previous_history(console) }
	if rl.IsKeyPressedRepeat(.DOWN) { next_history(console) }

	for character := rl.GetCharPressed(); character > 0; character = rl.GetCharPressed() {
		if character >= 32 && character <= 126 && console.input_len < Max_Input_Length {
			console.input[console.input_len] = u8(character)
			console.input_len += 1
		}
	}
}

// submit executes the current input line. It is public so headless validation
// tools can exercise registered commands without a raylib window.
submit :: proc(console: ^Console) {
	line := strings.trim_space(string(console.input[:console.input_len]))
	if len(line) == 0 { return }
	log_parts(console, .Info, {"> ", line})
	add_history(console, line)
	console.input_len = 0
	console.history_index = -1

	name_end := 0
	for name_end < len(line) && line[name_end] != ' ' && line[name_end] != '\t' { name_end += 1 }
	name := line[:name_end]
	arguments := strings.trim_space(line[name_end:])
	for index in 0..<console.command_count {
		command := &console.commands[index]
		if command_name(command) == name {
			command.handler(console, arguments)
			return
		}
	}
	log_parts(console, .Error, {"Unknown command: ", name})
}

draw :: proc(console: ^Console) {
	if !console.is_open { return }
	width := int(rl.GetScreenWidth())
	height := min(360, int(rl.GetScreenHeight()))
	padding := 12
	font_size := 18
	line_height := 23
	rl.DrawRectangle(0, 0, i32(width), i32(height), rl.Color{12, 15, 20, 232})
	draw_text("Rune Console  |  ` toggle  |  Esc close", padding, padding, font_size, rl.LIGHTGRAY)

	available_lines := (height - padding * 3 - line_height * 2) / line_height
	first := max(0, console.line_count - available_lines)
	for display_index in first..<console.line_count {
		line := console.lines[(console.line_start + display_index) % Max_Log_Lines]
		y := padding * 2 + line_height + (display_index - first) * line_height
		draw_text(string(line.text[:line.len]), padding, y, font_size, color_for_level(line.level))
	}

	input_y := height - padding - line_height
	rl.DrawRectangle(i32(padding - 4), i32(input_y - 3), i32(width - padding * 2 + 8), i32(line_height + 6), rl.Color{31, 38, 48, 255})
	draw_text("> ", padding, input_y, font_size, rl.RAYWHITE)
	draw_text(string(console.input[:console.input_len]), padding + 20, input_y, font_size, rl.RAYWHITE)
	draw_text("_", padding + 20 + console.input_len * 10, input_y, font_size, rl.RAYWHITE)
}

is_open :: proc(console: ^Console) -> bool { return console.is_open }

clear_command :: proc(console: ^Console, arguments: string) {
	console.line_start = 0
	console.line_count = 0
}

help_command :: proc(console: ^Console, arguments: string) {
	for index in 0..<console.command_count {
		command := console.commands[index]
		log_parts(console, .Info, {command_name(&command), " - ", command_description(&command)})
	}
}

add_history :: proc(console: ^Console, line: string) {
	if console.history_count < Max_History {
		console.history[console.history_count] = make_line(.Info, line)
		console.history_count += 1
		return
	}
	copy(console.history[:Max_History-1], console.history[1:])
	console.history[Max_History-1] = make_line(.Info, line)
}

previous_history :: proc(console: ^Console) {
	if console.history_count == 0 { return }
	if console.history_index < 0 { console.history_index = console.history_count - 1 } else if console.history_index > 0 { console.history_index -= 1 }
	copy_input(console, &console.history[console.history_index])
}

next_history :: proc(console: ^Console) {
	if console.history_index < 0 { return }
	if console.history_index >= console.history_count - 1 {
		console.history_index = -1
		console.input_len = 0
		return
	}
	console.history_index += 1
	copy_input(console, &console.history[console.history_index])
}

copy_input :: proc(console: ^Console, line: ^Log_Line) {
	console.input_len = line.len
	copy(console.input[:console.input_len], line.text[:line.len])
}

make_line :: proc(level: Log_Level, message: string) -> Log_Line {
	result := Log_Line{level = level}
	result.len = min(len(message), Max_Line_Length)
	copy(result.text[:result.len], message[:result.len])
	return result
}

command_name :: proc(command: ^Command) -> string { return string(command.name[:command.name_len]) }
command_description :: proc(command: ^Command) -> string { return string(command.description[:command.description_len]) }

color_for_level :: proc(level: Log_Level) -> rl.Color {
	switch level {
	case .Info: return rl.RAYWHITE
	case .Warning: return rl.YELLOW
	case .Error: return rl.MAROON
	}
	return rl.RAYWHITE
}

draw_text :: proc(text: string, x, y, font_size: int, color: rl.Color) {
	c_text, _ := strings.clone_to_cstring(text, context.temp_allocator)
	rl.DrawText(c_text, i32(x), i32(y), i32(font_size), color)
}

discard_characters :: proc() {
	for character := rl.GetCharPressed(); character > 0; character = rl.GetCharPressed() {}
}
