package ecs

import "core:encoding/json"
import "core:math"
import "core:testing"
import "rune:input"

@(test)
orbit_stick_and_zoom_are_independent_of_frame_rate :: proc(t: ^testing.T) {
	controls := input.Input{
		actions = make(map[string]input.Action_State),
		axes = make(map[string]f32),
		mappings = {axes = make(map[string]input.Axis)},
	}
	defer delete(controls.actions)
	defer delete(controls.axes)
	defer delete(controls.mappings.axes)
	controls.actions["orbit_camera"] = {is_down = true, strength = 1}
	controls.actions["zoom_out"] = {is_down = true, strength = 1}
	controls.mappings.axes["orbit_x_pad"] = {type = "gamepad_axis"}
	controls.mappings.axes["orbit_y_pad"] = {type = "gamepad_axis"}
	controls.axes["orbit_x_pad"], controls.axes["orbit_y_pad"] = 0.5, 0.1
	slow, fast := default_orbit_camera_3d(), default_orbit_camera_3d()
	for _ in 0..<30 {update_orbit_camera_3d(&slow, &controls, 1.0/30)}
	for _ in 0..<120 {update_orbit_camera_3d(&fast, &controls, 1.0/120)}
	testing.expect(t, math.abs(slow.yaw-fast.yaw) < 0.001 && math.abs(slow.pitch-fast.pitch) < 0.001)
	testing.expect(t, math.abs(slow.distance-fast.distance) < 0.001 && math.abs(slow.distance-16) < 0.001)
	before := slow
	controls.captured = true
	update_orbit_camera_3d(&slow, &controls, 1)
	testing.expect(t, slow == before, "modal capture gates stick and trigger queries")
	controls.captured = false
	controls.actions["orbit_camera"] = {}
	controls.actions["zoom_out"] = {}
	update_orbit_camera_3d(&slow, &controls, 1)
	testing.expect(t, slow == before, "stick rotation requires the manual action")
	controls.actions["zoom_out"] = {is_down = true, strength = 1}
	update_orbit_camera_3d(&slow, &controls, -1)
	testing.expect(t, slow == before, "invalid dt does not move gamepad controls")
	update_orbit_camera_3d(&slow, &controls, 100)
	testing.expect(t, slow.distance == slow.max_distance, "held zoom respects distance limits")
}

@(test)
orbit_gamepad_json_defaults_and_validation :: proc(t: ^testing.T) {
	documents := []string{
		`{}`, `{ "pad_orbit_speed": 0, "pad_zoom_speed": 0, "pad_yaw_axis": "", "zoom_in_action": "" }`,
		`{ "pad_orbit_speed": -1 }`, `{ "pad_zoom_speed": -1 }`, `{ "pad_pitch_axis": 2 }`,
	}
	for document, index in documents {
		value: json.Value
		testing.expect(t, json.unmarshal(transmute([]u8)document, &value) == nil)
		orbit, ok := orbit_camera_3d_from_json(value)
		if index == 0 {
			testing.expect(t, ok && orbit.pad_yaw_axis == "orbit_x_pad" && orbit.pad_pitch_axis == "orbit_y_pad")
			testing.expect(t, orbit.pad_orbit_speed == 180 && orbit.pad_zoom_speed == 8)
		} else {testing.expect(t, ok == (index == 1))}
		json.destroy_value(value)
	}
}
