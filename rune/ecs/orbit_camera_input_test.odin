package ecs

import "core:encoding/json"
import "core:math"
import "core:testing"
import "rune:input"

@(test)
orbit_horizontal_pan_preserves_height_and_screen_pan_keeps_its_basis :: proc(t: ^testing.T) {
	screen := default_orbit_camera_3d()
	screen.target = {4, 7, -2}
	screen.yaw, screen.pitch, screen.distance = 0, 60, 20
	screen.pan_sensitivity = 0.01
	screen.auto_yaw_speed = 90
	horizontal := screen
	horizontal.pan_mode = .horizontal
	controls := Orbit_Camera_Input{orbiting=true, panning=true, orbit_delta={100, 100}, pan_delta={2, 3}}
	update_orbit_camera_3d(&screen, controls, 1)
	update_orbit_camera_3d(&horizontal, controls, 1)
	testing.expect(t, screen.yaw == 0 && horizontal.yaw == 0 && screen.pitch == 60,
		"pan retains priority over manual orbit and automatic rotation")
	testing.expect(t, math.abs(screen.target[1]-7.3) < 0.0001,
		"the default screen-plane mode retains vertical camera-plane motion")
	testing.expect(t, horizontal.target[1] == 7 && math.abs(horizontal.target[0]-3.4) < 0.0001 && math.abs(horizontal.target[2]+1.6) < 0.0001,
		"horizontal drag uses camera yaw while preserving target height")
	rotated := default_orbit_camera_3d()
	rotated.pan_mode = .horizontal
	rotated.yaw, rotated.distance, rotated.pan_sensitivity = 90, 40, 0.01
	update_orbit_camera_3d(&rotated, Orbit_Camera_Input{panning=true, pan_delta={2, 3}}, 0)
	testing.expect(t, math.abs(rotated.target[0]+0.8) < 0.0001 && rotated.target[1] == 0 && math.abs(rotated.target[2]+1.2) < 0.0001,
		"horizontal pan rotates with yaw and scales with orbit distance")
}

@(test)
orbit_relative_zoom_scales_wheel_steps_and_preserves_pad_speed :: proc(t: ^testing.T) {
	absolute := default_orbit_camera_3d()
	absolute.distance, absolute.zoom_sensitivity = 40, 0.1
	relative := absolute
	relative.zoom_mode = .relative
	update_orbit_camera_3d(&absolute, Orbit_Camera_Input{zoom=1}, 0)
	update_orbit_camera_3d(&relative, Orbit_Camera_Input{zoom=1}, 0)
	testing.expect(t, math.abs(absolute.distance-39.9) < 0.0001 && relative.distance == 36,
		"legacy steps use world units while relative steps use current distance")
	update_orbit_camera_3d(&relative, Orbit_Camera_Input{pad_zoom=0.5}, 0.25)
	testing.expect(t, relative.distance == 37, "relative wheel mode keeps held gamepad zoom in world units per second")
	update_orbit_camera_3d(&relative, Orbit_Camera_Input{zoom=100}, 0)
	testing.expect(t, relative.distance == relative.min_distance)
	update_orbit_camera_3d(&relative, Orbit_Camera_Input{zoom=-10000}, 0)
	testing.expect(t, relative.distance == relative.max_distance, "both zoom directions respect distance limits")
}

@(test)
orbit_resolved_controls_match_mappings_without_changing_capture :: proc(t: ^testing.T) {
	controls := input.Input{
		actions = make(map[string]input.Action_State),
		axes = make(map[string]f32),
		mappings = {axes = make(map[string]input.Axis)},
	}
	defer delete(controls.actions)
	defer delete(controls.axes)
	defer delete(controls.mappings.axes)
	controls.actions["orbit_camera"] = {is_down=true, strength=1}
	controls.actions["zoom_out"] = {is_down=true, strength=0.5}
	for axis in ([]string{"orbit_x", "orbit_y", "zoom", "orbit_x_pad", "orbit_y_pad"}) {
		controls.mappings.axes[axis] = {type="mouse_delta"}
	}
	controls.axes["orbit_x"], controls.axes["orbit_y"], controls.axes["zoom"] = 2, -3, 1
	controls.axes["orbit_x_pad"], controls.axes["orbit_y_pad"] = 0.25, -0.1
	resolved := Orbit_Camera_Input{orbiting=true, orbit_delta={2, -3}, zoom=1, pad_orbit={0.25, -0.1}, pad_zoom=0.5}
	mapped, explicit := default_orbit_camera_3d(), default_orbit_camera_3d()
	mapped_pose := update_orbit_camera_3d(&mapped, &controls, 0.25)
	explicit_pose := update_orbit_camera_3d(&explicit, resolved, 0.25)
	testing.expect(t, mapped == explicit && mapped_pose == explicit_pose,
		"gameplay mappings adapt to the same resolved navigation path")
	controls.captured = true
	before := mapped
	update_orbit_camera_3d(&mapped, &controls, 0)
	testing.expect(t, mapped == before, "mapped controls retain modal capture")
	update_orbit_camera_3d(&explicit, Orbit_Camera_Input{orbiting=true, orbit_delta={2, 0}, zoom=1}, 0)
	testing.expect(t, explicit.yaw != mapped.yaw && explicit.distance < mapped.distance && controls.captured,
		"a tool can navigate with resolved mouse displacement during pause while gameplay stays captured")
}

@(test)
orbit_pose_evaluation_does_not_advance_auto_rotation :: proc(t: ^testing.T) {
	orbit := default_orbit_camera_3d()
	orbit.target, orbit.yaw, orbit.pitch, orbit.distance = {2, 3, 4}, 90, 0, 10
	orbit.auto_yaw_speed = 90
	before := orbit
	pose := orbit_camera_3d_pose(orbit)
	testing.expect(t, orbit == before && math.abs(pose.position[0]-2) < 0.0001 && pose.position[1] == 3 && pose.position[2] == 14 && pose.scale == ([3]f32{1, 1, 1}),
		"draw-only evaluation preserves orbit state and returns its world-space pose")
}

@(test)
orbit_navigation_modes_json_defaults_validation_and_roundtrip :: proc(t: ^testing.T) {
	for document, index in ([]string{
		`{}`, `{"pan_mode":"horizontal","zoom_mode":"relative","zoom_sensitivity":0.1}`,
		`{"pan_mode":"ground"}`, `{"pan_mode":1}`, `{"pan_mode":null}`,
		`{"zoom_mode":"fraction"}`, `{"zoom_mode":true}`, `{"zoom_mode":null}`,
	}) {
		value: json.Value
		assert(json.unmarshal(transmute([]u8)document, &value, allocator=context.temp_allocator) == nil)
		orbit, ok := orbit_camera_3d_from_json(value)
		testing.expect(t, ok == (index < 2), document)
		if index == 0 {
			testing.expect(t, orbit.pan_mode == .screen && orbit.zoom_mode == .absolute,
				"existing scenes retain their original pan plane and fixed zoom steps")
		} else if index == 1 {
			testing.expect(t, orbit.pan_mode == .horizontal && orbit.zoom_mode == .relative && orbit.zoom_sensitivity == 0.1)
			serialized, written := component_value_json(orbit)
			assert(written)
			object := serialized.(json.Object)
			testing.expect(t, (object["pan_mode"].(json.String) or_else "") == "horizontal" && (object["zoom_mode"].(json.String) or_else "") == "relative",
				"snapshots use scene enum names instead of numeric backing values")
			roundtrip, accepted := orbit_camera_3d_from_json(serialized)
			testing.expect(t, accepted && roundtrip == orbit, "runtime component snapshots preserve navigation mode enums")
		}
	}
}

@(test)
orbit_navigation_modes_runtime_edits_and_typed_validation :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w := init(); defer destroy(&w)
	r := init_registry(); defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	e := create_entity(&w)
	orbit := default_orbit_camera_3d()
	orbit.pan_mode, orbit.zoom_mode, orbit.zoom_sensitivity = .horizontal, .relative, 0.1
	assert(add(&w, &r, e, orbit))
	data, serialized := runtime_component_json(&w, e, "OrbitCamera3D")
	assert(serialized)
	copy := create_entity(&w)
	assert(add_component(&w, &r, copy, "OrbitCamera3D", data))
	roundtrip, found := get(&w, copy, OrbitCamera3D)
	testing.expect(t, found && roundtrip == orbit, "component snapshots reload both navigation modes")
	assert(set_runtime_field(&w, &r, e, "OrbitCamera3D", "pan_mode", json.String("screen")))
	assert(set_runtime_field(&w, &r, e, "OrbitCamera3D", "zoom_mode", json.String("absolute")))
	current, _ := get(&w, e, OrbitCamera3D)
	testing.expect(t, current.pan_mode == .screen && current.zoom_mode == .absolute && current.zoom_sensitivity == orbit.zoom_sensitivity,
		"inspector edits change one mode without corrupting the other fields")
	for field in ([]string{"pan_mode", "zoom_mode"}) {
		for bad in ([]json.Value{json.String("unknown"), json.Integer(1), json.Boolean(true)}) {
			testing.expect(t, !set_runtime_field(&w, &r, e, "OrbitCamera3D", field, bad))
			unchanged, _ := get(&w, e, OrbitCamera3D)
			testing.expect(t, unchanged == current, "invalid inspector modes preserve the valid component")
		}
	}
	for mode in 0..<2 {
		invalid := current
		if mode == 0 {invalid.pan_mode = Orbit_Pan_Mode(2)}
		else {invalid.zoom_mode = Orbit_Zoom_Mode(2)}
		testing.expect(t, !set_orbit_camera_3d(&w, e, invalid) && !set(&w, e, invalid) && !add(&w, &r, e, invalid),
			"typed mutations reject invalid enum casts before replacing a component")
		unchanged, _ := get(&w, e, OrbitCamera3D)
		testing.expect(t, unchanged == current)
		absent := create_entity(&w)
		testing.expect(t, !add(&w, &r, absent, invalid) && !has_component_data(&w, absent, "OrbitCamera3D"),
			"invalid typed modes cannot create components that fail snapshot reload")
	}
}
