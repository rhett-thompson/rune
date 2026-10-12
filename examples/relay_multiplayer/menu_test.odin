package main

import "core:testing"
import "core:sync"
import "rune:ui"

// Clay and Rune UI have one active context per process, including headless use.
menu_test_mutex: sync.Mutex

@(test)
room_code_normalizes_paste_and_rejects_invalid_codes :: proc(t: ^testing.T) {
	code, valid := normalize_code(" \t0123456789abcdef\r\n")
	testing.expect(t, valid)
	testing.expect_value(t, string(code[:]), "0123456789ABCDEF")
	invalid_codes := []string{"", "0123456789ABCDE", "0123456789ABCDEFG", "0123456789ABCDEG", "01234567 9ABCDEF", "０123456789ABCDEF"}
	for invalid in invalid_codes {
		_, ok := normalize_code(invalid)
		testing.expect(t, !ok, invalid)
	}
}

@(test)
menu_pastes_terminal_code_with_line_endings_without_losing_edit_ownership :: proc(t: ^testing.T) {
	state: Menu_State
	ui.text_field_set(&state.code_field, "old code")
	state.code_field.active, state.code_field.select_all = true, true
	state.error = "Previous attempt failed"
	testing.expect(t, menu_paste_code(&state, " \t0123456789abcdef\r\n"))
	testing.expect_value(t, ui.text_field_text(&state.code_field), "0123456789ABCDEF")
	testing.expect(t, state.code_field.active && !state.code_field.select_all && state.code_field.cursor == 16)
	testing.expect_value(t, state.error, "")
	state.code_field.select_all = true
	testing.expect(t, !menu_paste_code(&state, "not a room code\r\n"))
	testing.expect_value(t, ui.text_field_text(&state.code_field), "0123456789ABCDEF")
	testing.expect(t, state.code_field.select_all)
}

@(test)
relay_address_requires_a_real_port_and_supports_dns_and_ipv6 :: proc(t: ^testing.T) {
	valid_addresses := []string{"127.0.0.1:7777", " localhost:7777 ", "relay.example.com:443", "[::1]:7777", "[2001:db8::1]:65535"}
	for value in valid_addresses {
		testing.expect(t, menu_server_valid(value), value)
	}
	invalid_addresses := []string{"", "localhost", "127.0.0.1", "::1", "localhost:0", "localhost:-1", "localhost:+7777", "localhost:65536", "localhost:abc", ":7777", "bad host:7777"}
	for value in invalid_addresses {
		testing.expect(t, !menu_server_valid(value), value)
	}
}

menu_test_measure :: proc(value: string, size, spacing: f32) -> [2]f32 {return {f32(len(value))*size*0.5, size}}

menu_test_init :: proc(state: ^Menu_State) {
	assert(ui.init(&state.interface, measure = menu_test_measure))
	assert(ui.text_field_set(&state.server_field, "127.0.0.1:7777"))
}

menu_test_frame :: proc(state: ^Menu_State, controls: ui.Inputs = {}) -> Menu_Action {
	return menu_build(state, {960, 640}, controls, 1.0/60.0)
}

@(test)
menu_keyboard_join_commits_normalized_code_and_tab_does_not_join :: proc(t: ^testing.T) {
	sync.mutex_lock(&menu_test_mutex); defer sync.mutex_unlock(&menu_test_mutex)
	state: Menu_State
	menu_test_init(&state); defer ui.destroy(&state.interface)
	menu_test_frame(&state)
	testing.expect(t, ui.focused(&state.interface, "lobby-host"))
	testing.expect_value(t, menu_test_frame(&state, {activate = true}), Menu_Action.Host)
	menu_test_frame(&state, {next = true})
	testing.expect(t, ui.focused(&state.interface, "lobby-code"))
	menu_test_frame(&state, {activate = true})
	testing.expect(t, state.code_field.active)
	testing.expect(t, ui.text_field_insert(&state.code_field, "0123456789abcdef"))
	testing.expect_value(t, menu_test_frame(&state, {activate = true}), Menu_Action.Join)
	testing.expect_value(t, ui.text_field_text(&state.code_field), "0123456789ABCDEF")
	menu_test_frame(&state, {activate = true})
	testing.expect(t, state.code_field.active)
	testing.expect_value(t, menu_test_frame(&state, {next = true}), Menu_Action.None)
	testing.expect(t, !state.code_field.active && ui.focused(&state.interface, "lobby-join"))
	testing.expect_value(t, menu_test_frame(&state, {activate = true}), Menu_Action.Join)
}

@(test)
menu_blocks_bad_join_and_modal_input_but_allows_connection_cancel :: proc(t: ^testing.T) {
	sync.mutex_lock(&menu_test_mutex); defer sync.mutex_unlock(&menu_test_mutex)
	state: Menu_State
	menu_test_init(&state); defer ui.destroy(&state.interface)
	menu_test_frame(&state)
	menu_test_frame(&state, {next = true})
	menu_test_frame(&state, {activate = true})
	ui.text_field_insert(&state.code_field, "short")
	testing.expect_value(t, menu_test_frame(&state, {activate = true}), Menu_Action.None)
	menu_test_frame(&state, {next = true})
	testing.expect(t, ui.focused(&state.interface, "lobby-server"), "An invalid code skips the disabled Join button")
	state.busy = true
	menu_test_frame(&state)
	testing.expect(t, ui.focused(&state.interface, "lobby-cancel"))
	testing.expect_value(t, menu_test_frame(&state, {blocked = true, activate = true, cancel = true}), Menu_Action.None)
	testing.expect_value(t, menu_test_frame(&state, {cancel = true}), Menu_Action.Cancel)
	testing.expect_value(t, menu_test_frame(&state, {activate = true}), Menu_Action.Cancel)
}

@(test)
session_controls_copy_leave_and_return_after_room_closure :: proc(t: ^testing.T) {
	sync.mutex_lock(&menu_test_mutex); defer sync.mutex_unlock(&menu_test_mutex)
	state: Menu_State
	menu_test_init(&state); defer ui.destroy(&state.interface)
	menu_session_build(&state, {960, 640}, {}, 1.0/60.0, true)
	testing.expect_value(t, menu_session_build(&state, {960, 640}, {activate = true}, 1.0/60.0, true), Menu_Action.Copy_Code)
	menu_session_build(&state, {960, 640}, {next = true}, 1.0/60.0, true)
	testing.expect(t, ui.focused(&state.interface, "session-leave"))
	testing.expect_value(t, menu_session_build(&state, {960, 640}, {activate = true}, 1.0/60.0, true), Menu_Action.Leave)
	ui.reset_focus(&state.interface)
	menu_session_build(&state, {960, 640}, {}, 1.0/60.0, false)
	testing.expect(t, ui.focused(&state.interface, "session-leave"), "The return action receives focus after room closure")
	return_bounds, found := ui.bounds(&state.interface, "session-leave")
	testing.expect(t, found && return_bounds.width == 268, "The return action has room for its complete label")
	testing.expect_value(t, menu_session_build(&state, {960, 640}, {blocked = true, activate = true}, 1.0/60.0, false), Menu_Action.None)
	testing.expect_value(t, menu_session_build(&state, {960, 640}, {activate = true}, 1.0/60.0, false), Menu_Action.Leave)
}
