package core

import rl "vendor:raylib"

Cursor_Mode :: enum {visible, hidden, captured}

Cursor_State :: struct {
	mode: Cursor_Mode,
	known: bool,
	console_owned: bool,
	discard_mouse_delta: bool,
}

// The requested gameplay cursor mode. The console temporarily overrides it with
// a visible, unlocked pointer. Raylib exposes visibility but no lock query, so
// untracked raw HideCursor/DisableCursor calls are both inferred as captured.
// Use set_cursor_mode for exact restoration of a hidden, unlocked pointer.
cursor_mode :: proc(engine: ^Engine) -> Cursor_Mode {
	if engine == nil {return .visible}
	state := &engine.cursor
	if state.console_owned || !rl.IsWindowReady() {return state.mode}
	hidden := rl.IsCursorHidden()
	if !state.known || hidden != (state.mode != .visible) {return .captured if hidden else .visible}
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
	if engine.console.is_open {
		if !state.console_owned || rl.IsCursorHidden() {
			rl.EnableCursor()
			suppress_cursor_mouse_delta(engine)
		}
		state.console_owned = true
	} else {
		state.console_owned = false
		if was_owned || previous != mode {apply_cursor_mode(engine)}
	}
}

// begin_frame calls this before and after console.update. Custom loops using
// console.update directly may do the same. Only exported raylib APIs are used,
// so this works with both the static and shared raylib builds.
sync_console_cursor :: proc(engine: ^Engine) {
	if engine == nil || !rl.IsWindowReady() {return}
	state := &engine.cursor
	if engine.console.is_open {
		if !state.console_owned {
			state.mode = cursor_mode(engine)
			state.known, state.console_owned = true,true
			rl.EnableCursor()
			suppress_cursor_mouse_delta(engine)
		} else if rl.IsCursorHidden() {
			// A raw raylib caller should respect console focus. Recover on the
			// next update if it nevertheless hides or recaptures the pointer.
			rl.EnableCursor()
			suppress_cursor_mouse_delta(engine)
		}
	} else if state.console_owned {
		state.console_owned = false
		apply_cursor_mode(engine)
	}
}

@(private)
apply_cursor_mode :: proc(engine: ^Engine) {
	switch engine.cursor.mode {
	case .visible: rl.EnableCursor()
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
	for name, mapping in engine.input.mappings.axes {
		if mapping.type == "mouse_delta" {engine.input.axes[name] = 0}
	}
}
