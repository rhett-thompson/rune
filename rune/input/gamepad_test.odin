package input

import "core:math"
import "core:testing"

@(test)
gamepad_deadzone_preserves_analog_range :: proc(t: ^testing.T) {
	config := Axis{type="gamepad_axis", axis="LEFT_X", deadzone=0.2}
	for raw in ([5]f32{-0.2,-0.1,0,0.1,0.2}) {
		testing.expect(t,gamepad_axis_value(raw,config)==0,"drift inside the deadzone is suppressed")
	}
	testing.expect(t,abs(gamepad_axis_value(0.6,config)-0.5)<0.00001,"partial deflection stays analog")
	testing.expect(t,abs(gamepad_axis_value(-0.6,config)+0.5)<0.00001)
	testing.expect(t,gamepad_axis_value(1,config)==1 && gamepad_axis_value(-1,config)==-1,"full deflection remains full speed")
	testing.expect(t,gamepad_axis_value(3,config)==1,"raw values are bounded")
	testing.expect(t,gamepad_axis_value(math.nan_f32(),config)==0)
	config.invert=true; config.scale=2
	testing.expect(t,abs(gamepad_axis_value(0.6,config)+1)<0.00001,"invert and scale apply after deadzone")
}

@(test)
gamepad_mapping_validation :: proc(t: ^testing.T) {
	mappings := Mappings{actions=make(map[string][]Binding),axes=make(map[string]Axis)}
	defer delete(mappings.actions); defer delete(mappings.axes)
	valid := Axis{type="gamepad_axis",axis="RIGHT_Y",deadzone=0.18}
	for name in ([6]string{"LEFT_X","LEFT_Y","RIGHT_X","RIGHT_Y","LEFT_TRIGGER","RIGHT_TRIGGER"}) {
		config:=valid; config.axis=name; mappings.axes["stick"]=config
		testing.expect(t,validate_mappings(mappings),"all mapped platform axes load")
	}
	testing.expect(t,gamepad_axis_from_name("right_x").axis==.RIGHT_X,"names are case insensitive")
	for invalid in ([7]Axis{
		{type="gamepad_axis",axis="UNKNOWN"},
		{type="gamepad_axis",axis="LEFT_X",gamepad=-1},
		{type="gamepad_axis",axis="LEFT_X",deadzone=-0.1},
		{type="gamepad_axis",axis="LEFT_X",deadzone=1},
		{type="gamepad_axis",axis="LEFT_X",deadzone=math.nan_f32()},
		{type="gamepad_axis",axis="LEFT_X",deadzone=math.inf_f32(1)},
		{type="gamepad_axis",axis="LEFT_X",scale=math.inf_f32(1)},
	}) {
		mappings.axes["stick"]=invalid
		testing.expect(t,!validate_mappings(mappings),"invalid controller mappings are rejected")
	}
}

@(test)
gamepad_disconnect_and_multiple_device_edges :: proc(t: ^testing.T) {
	held:=Action_State{is_down=true,strength=1}
	press:=resolve_action_edges(held,{})
	testing.expect(t,press.pressed && !press.released)
	other_device_press:=resolve_action_edges({is_down=true,pressed=true,strength=1},held)
	testing.expect(t,!other_device_press.pressed,"another binding must not retrigger a held jump")
	other_device_release:=resolve_action_edges({is_down=true,released=true,strength=1},held)
	testing.expect(t,!other_device_release.released,"another held binding keeps a jump held")
	unplugged:=resolve_action_edges({},held)
	testing.expect(t,unplugged.released && !unplugged.is_down,"unplug releases without a platform edge")
	testing.expect(t,!resolve_action_edges({},{}).released,"disconnect releases only once")
	tap:=resolve_action_edges({pressed=true,released=true},{})
	testing.expect(t,tap.pressed && tap.released,"short taps between samples are retained")
}

@(test)
gamepad_axes_obey_modal_capture :: proc(t: ^testing.T) {
	controls:=Input{
		mappings={axes=make(map[string]Axis)},
		axes=make(map[string]f32),actions=make(map[string]Action_State),
	}
	defer delete(controls.mappings.axes); defer delete(controls.axes); defer delete(controls.actions)
	controls.mappings.axes["stick"]={type="gamepad_axis",axis="LEFT_X"}
	controls.axes["stick"]=0.5
	controls.actions["jump"]={is_down=true,pressed=true,strength=1}
	testing.expect(t,axis(&controls,"stick")==0.5)
	capture(&controls)
	testing.expect(t,axis(&controls,"stick")==0 && !is_down(&controls,"jump"),"menus suppress stick and button gameplay")
	testing.expect(t,frame_action(&controls,"jump").pressed,"UI can still read its captured actions")
}
