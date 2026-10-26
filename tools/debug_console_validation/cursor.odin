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
	// Synthetic device activity exercises actual raylib visibility with this
	// native window; hardware sampling/deadzones have separate pure tests.
	rune.set_cursor_mode(&game,.visible)
	rune.set_gamepad_cursor_auto_hide(&game,true)
	rune.begin_frame(&game)
	rl.SetMousePosition(137,97)
	pointer:=rl.GetMousePosition()
	game.input.activity={gamepad=true}
	rune.sync_cursor_activity(&game)
	assert(rl.IsCursorHidden() && rune.cursor_mode(&game)==.visible && rl.GetMousePosition()==pointer)
	rune.set_cursor_mode(&game,.visible)
	assert(rl.IsCursorHidden() && rl.GetMousePosition()==pointer,"a repeated menu request keeps gamepad visibility and pointer position")
	game.console.is_open=true
	rune.sync_console_cursor(&game)
	pointer=rl.GetMousePosition()
	assert(rl.IsCursorHidden() && rune.cursor_mode(&game)==.visible,"the unlocked console also follows gamepad visibility")
	game.input.activity={mouse_moved=true}
	rune.sync_cursor_activity(&game)
	assert(rl.IsCursorHidden(),"opening the console cannot reveal a gamepad-hidden pointer through its centering warp")
	game.input.activity={mouse_moved=true,gamepad=true}
	rune.sync_cursor_activity(&game)
	assert(!rl.IsCursorHidden() && rl.GetMousePosition()==pointer,"mouse wins and reveals at the same position")
	game.input.activity={gamepad=true}
	rune.sync_cursor_activity(&game)
	game.console.is_open=false
	rune.sync_console_cursor(&game)
	assert(rl.IsCursorHidden() && rune.cursor_mode(&game)==.visible,"closing the console preserves the gamepad preference")
	for mode in ([2]rune.Cursor_Mode{.hidden,.captured}) {
		rune.set_cursor_mode(&game,mode)
		game.input.activity={mouse_button_or_wheel=true}
		rune.sync_cursor_activity(&game)
		assert(rl.IsCursorHidden() && rune.cursor_mode(&game)==mode,"mouse activity cannot override explicit gameplay hiding/capture")
	}
	rune.set_cursor_mode(&game,.visible)
	assert(!rl.IsCursorHidden())
	game.input.activity={gamepad=true}
	rune.sync_cursor_activity(&game)
	pointer=rl.GetMousePosition()
	rune.set_gamepad_cursor_auto_hide(&game,false)
	assert(!rl.IsCursorHidden() && rl.GetMousePosition()==pointer,"disabling the policy reveals without warping")
	fmt.println("Console cursor: visible/hidden/captured restoration, live mode requests, raw FPS compatibility, and mouse-delta suppression passed")
	fmt.println("Gamepad cursor: opt-in hiding, mouse reveal/priority, no-warp setters, console and gameplay capture passed (synthetic activity)")
}
