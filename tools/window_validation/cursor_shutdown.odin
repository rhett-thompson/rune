package main

import "core:fmt"
import rune "rune:core"
import rl "vendor:raylib"

Native_Cursor_Info :: struct {size,flags:u32,handle:rawptr,position:[2]i32}
Native_Cursor_Clip :: struct {left,top,right,bottom:i32}
when ODIN_OS == .Windows {
	// Raylib already links User32. Do not import its conflicting CloseWindow.
	@(default_calling_convention="system")
	foreign {
		GetCursorInfo :: proc(info:^Native_Cursor_Info)->i32 ---
		GetClipCursor :: proc(rect:^Native_Cursor_Clip)->i32 ---
		GetForegroundWindow :: proc()->rawptr ---
	}
}

Shutdown_Cursor_Case :: enum {Visible, Hidden, Captured, Raw_Captured, Console_Owned}

validate_cursor_shutdown_case :: proc(mode:rune.Window_Mode,kind:Shutdown_Cursor_Case) {
	write_project(fmt.tprintf("%s%s%s",`{"width":320,"height":240,"mode":"`,rune.window_mode_name(mode),`","target_fps":60}`))
	game,ok:=rune.init(fixture)
	assert(ok)
	defer rune.shutdown(&game)
	rl.SetWindowFocused()
	when ODIN_OS == .Windows {
		// Windows may reject focus stealing from a background terminal. Native
		// cursor assertions require the real foreground owner, not GLFW's flag.
		deadline:=rl.GetTime()+30
		for GetForegroundWindow()!=rl.GetWindowHandle() && rl.GetTime()<deadline {
			rl.BeginDrawing();rl.ClearBackground(rl.BLACK);rl.EndDrawing()
		}
		assert(GetForegroundWindow()==rl.GetWindowHandle(),"focus the validation window before checking desktop cursor ownership")
	}
	rl.SetMousePosition(rl.GetScreenWidth()/2,rl.GetScreenHeight()/2)
	for _ in 0..<3 {rl.BeginDrawing();rl.ClearBackground(rl.BLACK);rl.EndDrawing()}
	assert(!rl.IsCursorHidden(),"a new engine must not inherit the previous window's hidden cursor")
	desktop_clip:Native_Cursor_Clip
	desktop_cursor:=Native_Cursor_Info{size=u32(size_of(Native_Cursor_Info))}
	when ODIN_OS == .Windows {
		assert(GetClipCursor(&desktop_clip)!=0)
		assert(GetCursorInfo(&desktop_cursor)!=0)
	}
	switch kind {
	case .Visible: rune.set_cursor_mode(&game,.visible)
	case .Hidden: rune.set_cursor_mode(&game,.hidden)
	case .Captured: rune.set_cursor_mode(&game,.captured)
	case .Raw_Captured: rl.DisableCursor()
	case .Console_Owned:
		game.console.is_open=true
		rune.set_cursor_mode(&game,.captured)
		// An untracked caller may hide the pointer while the console retains a
		// captured restore mode. Final cleanup must override both owners.
		rl.DisableCursor()
	}
	for _ in 0..<2 {rl.BeginDrawing();rl.ClearBackground(rl.BLACK);rl.EndDrawing()}
	expected_hidden:=kind!=.Visible
	observed_hidden:=rl.IsCursorHidden()==expected_hidden
	observed_native:=true
	hidden_cursor_handle:rawptr
	when ODIN_OS == .Windows {
		before:=Native_Cursor_Info{size=u32(size_of(Native_Cursor_Info))}
		before_clip:Native_Cursor_Clip
		observed_native=GetCursorInfo(&before)!=0 && GetClipCursor(&before_clip)!=0
		// Remote sessions may hide with a transparent cursor image while the
		// native SHOWING bit remains set. Its handle must still change.
		native_hidden:=before.flags&1==0 || before.handle!=desktop_cursor.handle
		if expected_hidden && before.flags&1!=0 && before.handle!=desktop_cursor.handle {hidden_cursor_handle=before.handle}
		observed_native=observed_native && native_hidden==expected_hidden
		// A borderless/fullscreen client may already cover the entire desktop.
		if mode==.Windowed && (kind==.Captured || kind==.Raw_Captured || kind==.Console_Owned) {observed_native=observed_native && before_clip!=desktop_clip}
	}
	// Always release the real captured pointer before asserting observations.
	rune.shutdown(&game)
	assert(observed_hidden,"the fixture exercised its requested cursor state")
	assert(!rl.IsWindowReady() && !rl.IsCursorHidden(),"shutdown closes the window with a visible cursor")
	assert(rune.cursor_mode(&game)==.visible && !game.cursor.console_owned,"shutdown cannot retain a console capture restore mode")
	when ODIN_OS == .Windows {
		after:=Native_Cursor_Info{size=u32(size_of(Native_Cursor_Info))}
		after_clip:Native_Cursor_Clip
		assert(observed_native,"the visible, focused fixture must actually hide/confine the native Windows pointer")
		assert(GetCursorInfo(&after)!=0 && after.flags&1!=0 && after.handle!=nil,"the desktop pointer is natively showing after shutdown")
		assert(hidden_cursor_handle==nil || after.handle!=hidden_cursor_handle,"shutdown replaces a remote session's transparent cursor image")
		assert(GetClipCursor(&after_clip)!=0 && after_clip==desktop_clip,"shutdown restores the original desktop cursor bounds")
	}
	rune.shutdown(&game)
	assert(rune.cursor_mode(&game)==.visible,"repeated shutdown cannot recapture the pointer")
	fmt.println("PASS cursor restored after shutdown:",mode,kind)
}

validate_cursor_shutdown_runtime :: proc() {
	for kind in Shutdown_Cursor_Case {validate_cursor_shutdown_case(.Windowed,kind)}
	validate_cursor_shutdown_case(.Borderless,.Captured)
	validate_cursor_shutdown_case(.Fullscreen,.Captured)
}
