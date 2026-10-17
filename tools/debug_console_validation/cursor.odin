package main

import "core:fmt"
import "rune:console"
import rune "rune:core"
import "rune:input"
import rl "vendor:raylib"

// Use the validator's hidden window to check public raylib visibility and Rune's
// tracked restore modes. This does not prove native focused-window pointer lock.
validate_console_cursor :: proc() {
	i,loaded := input.load("examples/terrain_3d/input/default.input.json"); assert(loaded)
	game := rune.Engine{console=console.init(),input=i}
	defer input.destroy(&game.input)
	defer console.destroy_renderer(&game.console)
	defer rune.set_cursor_mode(&game,.visible)
	for mode in ([3]rune.Cursor_Mode{.visible,.hidden,.captured}) {
		rune.set_cursor_mode(&game,mode)
		assert(rune.cursor_mode(&game)==mode && rl.IsCursorHidden()==(mode!=.visible))
		game.console.is_open=true
		rune.begin_frame(&game)
		assert(!rl.IsCursorHidden() && rune.cursor_mode(&game)==mode && game.cursor.console_owned)
		assert(game.input.captured && input.axis(&game.input,"look_x")==0,"console captures gameplay input while showing a free cursor")
		game.console.is_open=false
		rune.sync_console_cursor(&game)
		assert(rl.IsCursorHidden()==(mode!=.visible) && rune.cursor_mode(&game)==mode && !game.cursor.console_owned)
		assert(game.cursor.discard_mouse_delta,"restore suppresses the next warp delta")
		rune.begin_frame(&game)
		assert(!game.cursor.discard_mouse_delta && !game.input.captured)
		assert(input.axis(&game.input,"look_x")==0 && input.axis(&game.input,"look_y")==0)
	}
	// Repeated setters should not warp the pointer or suppress real movement.
	rune.set_cursor_mode(&game,.captured)
	rune.begin_frame(&game)
	game.input.axes["look_x"]=7
	rune.set_cursor_mode(&game,.captured)
	assert(!game.cursor.discard_mouse_delta && input.axis(&game.input,"look_x")==7)
	game.console.is_open=true
	rune.sync_console_cursor(&game)
	rune.set_cursor_mode(&game,.hidden)
	assert(!rl.IsCursorHidden() && rune.cursor_mode(&game)==.hidden,"a request while open updates restoration without hiding the console cursor")
	game.console.is_open=false
	rune.sync_console_cursor(&game)
	assert(rl.IsCursorHidden() && rune.cursor_mode(&game)==.hidden)
	rune.set_cursor_mode(&game,.visible)
	// Existing games can still start mouse look with a direct raylib call.
	rl.DisableCursor()
	game.console.is_open=true
	rune.sync_console_cursor(&game)
	assert(!rl.IsCursorHidden() && rune.cursor_mode(&game)==.captured)
	rl.DisableCursor()
	rune.sync_console_cursor(&game)
	assert(!rl.IsCursorHidden(),"a raw relock is released on the next console sync")
	game.console.is_open=false
	rune.sync_console_cursor(&game)
	assert(rl.IsCursorHidden() && rune.cursor_mode(&game)==.captured)
	fmt.println("Console cursor: visible/hidden/captured restoration, live mode requests, raw FPS compatibility, and mouse-delta suppression passed")
}
