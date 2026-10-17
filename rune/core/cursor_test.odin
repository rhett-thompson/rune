package core

import "core:testing"
import "rune:input"

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
	discard_cursor_mouse_delta(&game)
	testing.expect(t,!game.cursor.discard_mouse_delta && input.axis(&game.input,"look_x")==0 && input.axis(&game.input,"look_y")==0)
	testing.expect(t,input.axis(&game.input,"scroll")==2 && input.axis(&game.input,"stick")==0.75)
	game.input.axes["look_x"]=4
	discard_cursor_mouse_delta(&game)
	testing.expect(t,input.axis(&game.input,"look_x")==4,"the following frame accepts real movement")
}
