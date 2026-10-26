package core

import "rune:console"
import rl "vendor:raylib"

Cursor_Mode :: enum {visible, hidden, captured}

Cursor_State :: struct {
	mode: Cursor_Mode,
	known: bool,
	console_owned: bool,
	discard_mouse_delta: bool,
	// Opt-in visibility policy; mode still describes the requested capture.
	gamepad_auto_hide: bool,
	gamepad_hidden: bool,
}

// The requested gameplay cursor mode. The console temporarily uses an unlocked
// pointer; optional gamepad activity can hide it. Raylib has no lock query, so
// untracked raw HideCursor/DisableCursor calls are inferred as captured when
// visibility changes. Auto-hide clients must use set_cursor_mode consistently:
// raw capture cannot be distinguished while the pointer is already auto-hidden.
cursor_mode :: proc(engine: ^Engine) -> Cursor_Mode {
	if engine == nil {return .visible}
	state := &engine.cursor
	if state.console_owned || !rl.IsWindowReady() {return state.mode}
	hidden := rl.IsCursorHidden()
	if !state.known || hidden != (state.mode != .visible || gamepad_cursor_hidden(engine)) {return .captured if hidden else .visible}
	return state.mode
}

// Call after init creates the engine's window. Changes made while the console
// is open become its restore mode; gameplay cannot accidentally recapture the
// console's pointer through this API.
set_cursor_mode :: proc(engine: ^Engine, mode: Cursor_Mode) {
	if engine == nil || mode < .visible || mode > .captured {return}
	state := &engine.cursor
	previous, was_owned := cursor_mode(engine),state.console_owned
	state.mode, state.known = mode,true
	if !rl.IsWindowReady() {return}
	if console.is_open(&engine.console) {
		if !state.console_owned || (rl.IsCursorHidden() && !gamepad_cursor_hidden(engine)) {
			rl.EnableCursor()
			suppress_cursor_mouse_delta(engine)
		}
		state.console_owned = true
		apply_free_cursor_visibility(engine)
	} else {
		state.console_owned = false
		if was_owned || previous != mode {apply_cursor_mode(engine)}
	}
}

// Hide a free pointer after gamepad activity and reveal it on mouse use. This
// leaves explicit hidden/captured modes intact and is disabled by default.
set_gamepad_cursor_auto_hide :: proc(engine: ^Engine, enabled: bool) {
	if engine == nil || engine.cursor.gamepad_auto_hide == enabled {return}
	mode := cursor_mode(engine)
	engine.cursor.mode, engine.cursor.known = mode,true
	engine.cursor.gamepad_auto_hide = enabled
	if !enabled {engine.cursor.gamepad_hidden = false}
	if rl.IsWindowReady() && (engine.cursor.console_owned || mode == .visible) {
		apply_free_cursor_visibility(engine)
	}
}

// Call after input.update in custom loops. Activity remains available while
// gameplay input is captured by a menu. Mouse use wins simultaneous activity.
sync_cursor_activity :: proc(engine: ^Engine) {
	if engine == nil {return}
	discard_cursor_mouse_delta(engine)
	if !engine.cursor.gamepad_auto_hide {return}
	state := &engine.cursor
	mode := cursor_mode(engine)
	previous := state.gamepad_hidden
	activity := engine.input.activity
	if activity.mouse_moved || activity.mouse_button_or_wheel {state.gamepad_hidden = false}
	else if activity.gamepad {state.gamepad_hidden = true}
	if previous != state.gamepad_hidden && rl.IsWindowReady() && (state.console_owned || mode == .visible) {
		apply_free_cursor_visibility(engine)
	}
}

@(private)
gamepad_cursor_hidden :: proc(engine: ^Engine) -> bool {
	return engine.cursor.gamepad_auto_hide && engine.cursor.gamepad_hidden
}

// Show/Hide change visibility without EnableCursor's centering warp.
@(private)
apply_free_cursor_visibility :: proc(engine: ^Engine) {
	if gamepad_cursor_hidden(engine) {rl.HideCursor()}
	else {rl.ShowCursor()}
}

// Restore the pointer while GLFW still owns a live window. Destroying a
// captured window may release confinement without refreshing the cursor image.
// Shutdown is final: a console restore mode must not capture it again.
@(private)
restore_shutdown_cursor :: proc(engine: ^Engine) {
	if engine == nil {return}
	if rl.IsWindowReady() {rl.EnableCursor()}
	engine.cursor = {mode=.visible,known=true}
}

// begin_frame calls this before and after console.update. Custom loops using
// console.update directly may do the same. Only exported raylib APIs are used,
// so this works with both the static and shared raylib builds.
sync_console_cursor :: proc(engine: ^Engine) {
	if engine == nil || !rl.IsWindowReady() {return}
	state := &engine.cursor
	if console.is_open(&engine.console) {
		if !state.console_owned {
			state.mode = cursor_mode(engine)
			state.known, state.console_owned = true,true
			rl.EnableCursor()
			suppress_cursor_mouse_delta(engine)
		} else if rl.IsCursorHidden() && !gamepad_cursor_hidden(engine) {
			// A raw raylib caller should respect console focus. Recover on the
			// next update if it nevertheless hides or recaptures the pointer.
			rl.EnableCursor()
			suppress_cursor_mouse_delta(engine)
		}
		apply_free_cursor_visibility(engine)
	} else if state.console_owned {
		state.console_owned = false
		apply_cursor_mode(engine)
	}
}

@(private)
apply_cursor_mode :: proc(engine: ^Engine) {
	switch engine.cursor.mode {
	case .visible: rl.EnableCursor(); apply_free_cursor_visibility(engine)
	case .hidden: rl.EnableCursor(); rl.HideCursor()
	case .captured: rl.DisableCursor()
	}
	suppress_cursor_mouse_delta(engine)
}

@(private)
suppress_cursor_mouse_delta :: proc(engine: ^Engine) {
	for name, mapping in engine.input.mappings.axes {
		if mapping.type == "mouse_delta" {engine.input.axes[name] = 0}
	}
	engine.cursor.discard_mouse_delta = true
}

// A cursor-mode change can warp the pointer during the preceding frame.
// Discard just the next sampled mouse delta, preserving keyboard/pad movement.
@(private)
discard_cursor_mouse_delta :: proc(engine: ^Engine) {
	if !engine.cursor.discard_mouse_delta {return}
	engine.cursor.discard_mouse_delta = false
	engine.input.activity.mouse_moved = false
	for name, mapping in engine.input.mappings.axes {
		if mapping.type == "mouse_delta" {engine.input.axes[name] = 0}
	}
}
