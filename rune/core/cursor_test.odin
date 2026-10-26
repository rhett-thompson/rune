package core

import "core:testing"
import "rune:input"

@(test)
cursor_shutdown_clears_hidden_and_console_restore_modes_without_a_window :: proc(t: ^testing.T) {
	for mode in Cursor_Mode {
		game:=Engine{cursor={mode=mode,known=true,console_owned=true,discard_mouse_delta=true,gamepad_auto_hide=true,gamepad_hidden=true}}
		restore_shutdown_cursor(&game)
		testing.expect(t,cursor_mode(&game)==.visible && game.cursor.known && !game.cursor.console_owned && !game.cursor.discard_mouse_delta,
			"a closed engine cannot retain a hidden pointer or a console's captured restore mode")
		testing.expect(t,!game.cursor.gamepad_auto_hide && !game.cursor.gamepad_hidden,"shutdown clears device visibility policy")
		restore_shutdown_cursor(&game)
		testing.expect(t,cursor_mode(&game)==.visible,"repeated cleanup remains visible")
	}
	restore_shutdown_cursor(nil)
}

@(test)
cursor_activity_preserves_capture_and_prioritizes_mouse_without_a_window :: proc(t: ^testing.T) {
	game: Engine
	game.input.activity = {gamepad=true}
	sync_cursor_activity(&game)
	testing.expect(t,!game.cursor.gamepad_hidden,"controller visibility changes require opt-in")
	set_gamepad_cursor_auto_hide(&game,true)
	for mode in Cursor_Mode {
		set_cursor_mode(&game,mode)
		game.input.captured = true
		game.input.activity = {gamepad=true}
		sync_cursor_activity(&game)
		testing.expect(t,game.cursor.gamepad_hidden && cursor_mode(&game)==mode,"menus can hide the pointer without changing requested capture")
		game.input.activity = {}
		sync_cursor_activity(&game)
		testing.expect(t,game.cursor.gamepad_hidden,"no activity keeps the prior device preference")
		game.input.activity = {mouse_moved=true,gamepad=true}
		sync_cursor_activity(&game)
		testing.expect(t,!game.cursor.gamepad_hidden && cursor_mode(&game)==mode,"mouse movement wins simultaneous input without releasing capture")
		game.input.activity = {gamepad=true}
		sync_cursor_activity(&game)
		game.input.activity = {mouse_button_or_wheel=true}
		sync_cursor_activity(&game)
		testing.expect(t,!game.cursor.gamepad_hidden,"a click or wheel gesture reveals a stationary mouse")
	}
	game.input.activity = {gamepad=true}
	sync_cursor_activity(&game)
	game.cursor.discard_mouse_delta = true
	game.input.activity = {mouse_moved=true}
	sync_cursor_activity(&game)
	testing.expect(t,game.cursor.gamepad_hidden,"custom-loop activity sync ignores a cursor-mode warp")
	game.cursor.discard_mouse_delta = true
	game.input.activity = {mouse_moved=true,mouse_button_or_wheel=true}
	sync_cursor_activity(&game)
	testing.expect(t,!game.cursor.gamepad_hidden,"a real click still reveals the pointer during warp suppression")
	set_gamepad_cursor_auto_hide(&game,false)
	testing.expect(t,!game.cursor.gamepad_hidden && !game.cursor.gamepad_auto_hide,"disabling the option clears its hidden preference")
	sync_cursor_activity(nil)
	set_gamepad_cursor_auto_hide(nil,true)
}

@(test)
cursor_warp_suppression_only_discards_mouse_delta_once :: proc(t: ^testing.T) {
	game := Engine{input=input.Input{
		mappings={axes=make(map[string]input.Axis)},axes=make(map[string]f32),
	}}
	defer delete(game.input.mappings.axes); defer delete(game.input.axes)
	game.input.mappings.axes["look_x"]={type="mouse_delta",axis="x"}
	game.input.mappings.axes["look_y"]={type="mouse_delta",axis="y"}
	game.input.mappings.axes["scroll"]={type="mouse_wheel"}
	game.input.mappings.axes["stick"]={type="gamepad_axis"}
	game.input.axes["look_x"]=90; game.input.axes["look_y"]=-45
	game.input.axes["scroll"]=2; game.input.axes["stick"]=0.75
	suppress_cursor_mouse_delta(&game)
	testing.expect(t,game.input.axes["look_x"]==0 && game.input.axes["look_y"]==0)
	testing.expect(t,game.cursor.discard_mouse_delta && game.input.axes["scroll"]==2 && game.input.axes["stick"]==0.75)
	// Simulate the next input sample after an OS cursor warp.
	game.input.axes["look_x"]=300; game.input.axes["look_y"]=200
	game.input.activity = {mouse_moved=true,mouse_button_or_wheel=true,gamepad=true}
	discard_cursor_mouse_delta(&game)
	testing.expect(t,!game.cursor.discard_mouse_delta && input.axis(&game.input,"look_x")==0 && input.axis(&game.input,"look_y")==0)
	testing.expect(t,input.axis(&game.input,"scroll")==2 && input.axis(&game.input,"stick")==0.75)
	testing.expect(t,game.input.activity==input.Device_Activity{mouse_button_or_wheel=true,gamepad=true},"a warp cannot reveal the pointer, but click/wheel and controller activity survive")
	game.input.axes["look_x"]=4
	discard_cursor_mouse_delta(&game)
	testing.expect(t,input.axis(&game.input,"look_x")==4,"the following frame accepts real movement")
}
