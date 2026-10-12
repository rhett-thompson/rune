package main

import example_text "../shared/text"
import "core:net"
import "rune:console"
import rune "rune:core"
import "rune:input"
import "rune:ui"
import rl "vendor:raylib"

Menu_Action :: enum {None, Host, Join, Cancel, Leave, Copy_Code}

Menu_State :: struct {
	interface: ui.Context,
	server_field, code_field: ui.Text_Field,
	initialized, busy: bool,
	session_keyboard: bool,
	error: string,
}

// Clay keeps pointers into its context, so this state stays at one address.
lobby: Menu_State

menu_trim_space :: proc(value: string) -> string {
	start, end := 0, len(value)
	for start < end && menu_ascii_space(value[start]) {start += 1}
	for end > start && menu_ascii_space(value[end-1]) {end -= 1}
	return value[start:end]
}

menu_ascii_space :: proc(character: u8) -> bool {
	return character == ' ' || character == '\t' || character == '\n' ||
	       character == '\r' || character == '\v' || character == '\f'
}

// Copy into fixed storage so callers can retain the normalized code after an edit.
normalize_code :: proc(value: string) -> (code: [16]u8, valid: bool) {
	trimmed := menu_trim_space(value)
	if len(trimmed) != len(code) {return {}, false}
	for byte, index in transmute([]u8)trimmed {
		character := byte
		if character >= 'a' && character <= 'f' {character -= 'a' - 'A'}
		if !(character >= '0' && character <= '9') && !(character >= 'A' && character <= 'F') {return {}, false}
		code[index] = character
	}
	return code, true
}

menu_server_valid :: proc(value: string) -> bool {
	trimmed := menu_trim_space(value)
	target, err := net.parse_hostname_or_endpoint(trimmed)
	if err != .None {return false}
	port: int
	switch address in target {
	case net.Host: port = address.port
	case net.Endpoint: port = address.port
	case: return false
	}
	if port <= 0 || port > 65535 {return false}
	// The network parser accepts signed integers; a menu port is decimal digits.
	separator := -1
	for character, index in trimmed {if character == ':' {separator = index}}
	if separator < 0 || separator+1 >= len(trimmed) {return false}
	for character in trimmed[separator+1:] {if character < '0' || character > '9' {return false}}
	return true
}

menu_server :: proc(state: ^Menu_State) -> string {return menu_trim_space(ui.text_field_text(&state.server_field))}
menu_code :: proc(state: ^Menu_State) -> (code: [16]u8, valid: bool) {return normalize_code(ui.text_field_text(&state.code_field))}

// Terminal clipboard selections often include a line ending. Replace the whole
// code only for a valid complete code; ordinary partial edits stay with Text_Field.
menu_paste_code :: proc(state: ^Menu_State, value: string) -> bool {
	code, valid := normalize_code(value)
	if !valid {return false}
	if !ui.text_field_set(&state.code_field, string(code[:])) {return false}
	state.error = ""
	return true
}

menu_init :: proc(server: string = "127.0.0.1:7777", room_code: string = "") -> bool {
	if lobby.initialized {return false}
	if !ui.text_field_set(&lobby.server_field, server) || !ui.text_field_set(&lobby.code_field, room_code) {return false}
	if !ui.init(&lobby.interface, example_text.font()) {return false}
	lobby.interface.style.accent = {255, 183, 87, 255}
	lobby.interface.style.pressed = {51, 74, 103, 255}
	lobby.interface.style.surface = {29, 43, 63, 255}
	lobby.interface.style.hover = {43, 64, 90, 255}
	lobby.interface.style.height = 42
	lobby.interface.style.font_size = 18
	lobby.initialized = true
	return true
}

menu_destroy :: proc() {
	if lobby.initialized {ui.destroy(&lobby.interface)}
	lobby = {}
}

// Separating layout from device reads keeps keyboard focus, validation, and
// connection cancellation testable without a graphics window.
menu_build :: proc(state: ^Menu_State, dimensions: [2]f32, controls: ui.Inputs, dt: f32) -> Menu_Action {
	interface := &state.interface
	if !ui.begin(interface, dimensions, controls, dt) {return .None}
	action: Menu_Action
	server_valid := menu_server_valid(menu_server(state))
	_, code_valid := menu_code(state)
	enabled := !state.busy
	ui.panel(interface, "lobby-screen", {
		layout = {sizing = {width = ui.grow({}), height = ui.grow({})}, padding = ui.padding(20), childAlignment = {x = .Center, y = .Center}},
		backgroundColor = {13, 19, 31, 255},
	})
	ui.panel(interface, "lobby-panel", {
		layout = {sizing = {width = ui.grow({max = 500}), height = ui.fit({})}, layoutDirection = .TopToBottom, padding = ui.padding(24), childGap = 10},
		backgroundColor = {18, 28, 43, 255}, cornerRadius = ui.corners(12),
		border = {color = {48, 64, 86, 255}, width = {left = 1, right = 1, top = 1, bottom = 1}},
	})
	ui.label(interface, "RELAY ARENA", interface.style.text, 36)
	ui.label(interface, "Two players. One shared world.", interface.style.muted, 16)
	if ui.button(interface, "lobby-host", "Host game", enabled && server_valid) {action = .Host}
	ui.label(interface, "Or join a friend's room", interface.style.muted, 14)
	ui.label(interface, "Room code", interface.style.text, 15)
	code_edit := ui.text_input(interface, "lobby-code", &state.code_field, enabled)
	ui.label(interface, "Paste the host's 16-character code, e.g. 0123456789ABCDEF", interface.style.muted, 12)
	// Tab also commits text fields. Only Enter explicitly submits the code.
	if code_edit.committed && controls.activate && ui.focused(interface, "lobby-code") && enabled && code_valid && server_valid {action = .Join}
	if ui.button(interface, "lobby-join", "Join game", enabled && code_valid && server_valid) {action = .Join}
	ui.label(interface, "Relay address", interface.style.text, 15)
	server_edit := ui.text_input(interface, "lobby-server", &state.server_field, enabled)
	if code_edit.changed || server_edit.changed {state.error = ""}
	if !server_valid {ui.label(interface, "Enter a relay host and port, e.g. 127.0.0.1:7777", {255, 120, 127, 255}, 14)}
	else if state.error != "" {ui.label(interface, state.error, {255, 120, 127, 255}, 14)}
	if state.busy {
		ui.label(interface, "Connecting to the relay...", interface.style.muted, 15)
		if ui.button(interface, "lobby-cancel", "Cancel") || (controls.cancel && !controls.blocked) {action = .Cancel}
	} else {
		ui.label(interface, "TAB  Navigate    ENTER  Select / join    CTRL+V  Paste", interface.style.muted, 12)
	}
	ui.end_panel(interface)
	ui.end_panel(interface)
	if !ui.finish(interface) {return .None}
	if action == .Join {
		code, valid := menu_code(state)
		if !valid || !menu_server_valid(menu_server(state)) {return .None}
		ui.text_field_set(&state.code_field, string(code[:]))
	}
	return action
}

menu_update :: proc(engine: ^rune.Engine) -> Menu_Action {
	if !lobby.initialized {return .None}
	ui.set_font(&lobby.interface, example_text.font())
	controls := ui.read_input(&lobby.interface, rune.input_state(engine), engine.frame_delta_time)
	controls.blocked = console.is_open(rune.developer_console(engine)) || rune.input_state(engine).captured || !rl.IsWindowFocused()
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	if lobby.code_field.active || lobby.server_field.active {
		// Arrow keys edit the active field rather than changing menu focus.
		controls.next = rl.IsKeyPressed(.TAB) && !shift
		controls.previous = rl.IsKeyPressed(.TAB) && shift
	} else if rl.IsKeyPressed(.TAB) {
		controls.next, controls.previous = !shift, shift
	}
	controls.activate = controls.activate || rl.IsKeyPressed(.KP_ENTER)
	control := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	paste_code := lobby.code_field.active && control && rl.IsKeyPressed(.V) && !controls.blocked
	input.capture(rune.input_state(engine))
	action := menu_build(&lobby, {f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}, controls, engine.frame_delta_time)
	if paste_code {
		if pasted := rl.GetClipboardText(); pasted != nil {menu_paste_code(&lobby, string(pasted))}
	}
	return action
}

menu_draw :: proc() {if lobby.initialized {ui.draw(&lobby.interface)}}

menu_session_build :: proc(state: ^Menu_State, dimensions: [2]f32, controls: ui.Inputs, dt: f32, can_copy: bool) -> Menu_Action {
	interface := &state.interface
	if !ui.begin(interface, dimensions, controls, dt) {return .None}
	previous_height, previous_size := interface.style.height, interface.style.font_size
	interface.style.height, interface.style.font_size = 42, 14
	defer {interface.style.height, interface.style.font_size = previous_height, previous_size}
	action: Menu_Action
	ui.panel(interface, "session-screen", {layout = {sizing = {width = ui.grow({}), height = ui.grow({})}}})
	ui.panel(interface, "session-controls", {
		layout = {sizing = {width = ui.fixed(268), height = ui.fixed(42)}, childGap = 12},
		floating = {attachTo = .Root, attachment = {element = .RightTop, parent = .RightTop}, offset = {-40, 100}},
	})
	if can_copy {
		ui.panel(interface, "session-copy-slot", {layout = {sizing = {width = ui.fixed(136), height = ui.fixed(42)}}})
		if ui.button(interface, "session-copy", "Copy code") {action = .Copy_Code}
		ui.end_panel(interface)
	}
	ui.panel(interface, "session-leave-slot", {layout = {sizing = {width = ui.fixed(120 if can_copy else 268), height = ui.fixed(42)}}})
	if ui.button(interface, "session-leave", "Leave game" if can_copy else "Return to menu") {action = .Leave}
	ui.end_panel(interface)
	ui.end_panel(interface)
	ui.end_panel(interface)
	if !ui.finish(interface) {return .None}
	return action
}

menu_session_update :: proc(engine: ^rune.Engine, can_copy: bool) -> Menu_Action {
	if !lobby.initialized {return .None}
	ui.set_font(&lobby.interface, example_text.font())
	controls := ui.read_input(rune.input_state(engine))
	controls.blocked = console.is_open(rune.developer_console(engine)) || rune.input_state(engine).captured || !rl.IsWindowFocused()
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	tab_pressed := rl.IsKeyPressed(.TAB) && !controls.blocked
	if tab_pressed {lobby.session_keyboard = true}
	if controls.cancel && !controls.blocked {lobby.session_keyboard = false}
	controls.next, controls.previous = tab_pressed && !shift, tab_pressed && shift
	controls.left, controls.right = false, false
	controls.activate = lobby.session_keyboard && (controls.activate || rl.IsKeyPressed(.KP_ENTER))
	action := menu_session_build(&lobby, {f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}, controls, engine.frame_delta_time, can_copy)
	if tab_pressed || action != .None {input.capture(rune.input_state(engine))}
	return action
}
