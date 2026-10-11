package main

import "core:testing"
import "rune:ecs"
import "rune:input"

@(test)
pointer_panel_hover_masks_mouse_but_keeps_controller_camera :: proc(t:^testing.T) {
	controls := input.Input{
		actions=make(map[string]input.Action_State),
		axes=make(map[string]f32),
		mappings={axes=make(map[string]input.Axis)},
	}
	defer delete(controls.actions);defer delete(controls.axes);defer delete(controls.mappings.axes)
	for name in ([]string{"orbit_x","orbit_y","zoom","orbit_x_pad","orbit_y_pad"}) {
		controls.mappings.axes[name]={type="gamepad_axis"}
	}
	controls.axes["orbit_x"],controls.axes["orbit_y"],controls.axes["zoom"]=100,100,100
	controls.axes["orbit_x_pad"],controls.axes["orbit_y_pad"]=0.5,0.25
	controls.actions["orbit_camera"]={is_down=true,strength=1}
	controls.actions["orbit_pad_hold"]={is_down=true,strength=1}
	controls.actions["zoom_in"]={is_down=true,strength=1}
	orbit:=ecs.default_orbit_camera_3d();orbit.yaw=0;orbit.pitch=0;orbit.distance=10
	course_camera_pose(&orbit,&controls,0.1,true)
	testing.expect(t,abs(orbit.yaw-351)<0.0001 && abs(orbit.pitch-4.5)<0.0001,
		"panel hover leaves only dt-scaled stick orbit")
	testing.expect(t,abs(orbit.distance-9.2)<0.0001,"mouse wheel is masked while pad zoom remains")
	testing.expect(t,orbit.manual_action=="orbit_camera" && orbit.yaw_axis=="orbit_x" && orbit.pitch_axis=="orbit_y" && orbit.zoom_axis=="zoom",
		"temporary mouse masking restores the authored input fields")
	controls.actions["orbit_pad_hold"]={}
	before:=orbit
	course_camera_pose(&orbit,&controls,0.1,true)
	testing.expect(t,orbit.yaw==before.yaw && orbit.pitch==before.pitch,
		"held mouse button does not orbit through the panel")
	controls.actions["zoom_in"]={}
	controls.axes["orbit_x_pad"],controls.axes["orbit_y_pad"]=0,0
	course_camera_pose(&orbit,&controls,0.1,false)
	testing.expect(t,orbit.yaw!=before.yaw,"mouse gestures resume outside the panel")
}
