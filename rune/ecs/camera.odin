package ecs

import "core:encoding/json"
import "core:math"
import "rune:input"

// Camera2D uses the entity Transform position as its world-space target. Offset
// is the screen-space point where that target is drawn.
Camera2D :: struct {
	offset:   [2]f32,
	zoom:     f32,
	rotation: f32,
	active:   bool,
}

// Camera3D uses the entity Transform position as its world-space position.
// Target and up remain explicit because they describe the view direction.
Camera3D :: struct {
	target: [3]f32,
	up:     [3]f32,
	fovy:   f32,
	active: bool,
}

OrbitCamera3D :: struct {
	target:             [3]f32,
	yaw:                f32,
	pitch:              f32,
	distance:           f32,
	min_pitch:          f32,
	max_pitch:          f32,
	min_distance:       f32,
	max_distance:       f32,
	auto_yaw_speed:     f32,
	manual_action:      string,
	yaw_axis:           string,
	pitch_axis:         string,
	zoom_axis:          string,
	orbit_sensitivity:  f32,
	zoom_sensitivity:   f32,
}

default_camera_2d :: proc() -> Camera2D {
	return Camera2D{zoom = 1}
}

default_camera_3d :: proc() -> Camera3D {
	return Camera3D{target = {0, 0, 0}, up = {0, 1, 0}, fovy = 45}
}

default_orbit_camera_3d :: proc() -> OrbitCamera3D {
	return OrbitCamera3D{
		distance = 8,
		pitch = 25,
		min_pitch = -80,
		max_pitch = 80,
		min_distance = 1,
		max_distance = 100,
		manual_action = "orbit_camera",
		yaw_axis = "orbit_x",
		pitch_axis = "orbit_y",
		zoom_axis = "zoom",
		orbit_sensitivity = 0.35,
		zoom_sensitivity = 1,
	}
}

camera_2d_from_json :: proc(data: json.Value) -> (Camera2D, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }

	result := default_camera_2d()
	if value, found := object["offset"]; found && !read_vector2(value, &result.offset) { return {}, false }
	if value, found := object["zoom"]; found {
		result.zoom, ok = read_number(value)
		if !ok || result.zoom <= 0 { return {}, false }
	}
	if value, found := object["rotation"]; found {
		result.rotation, ok = read_number(value)
		if !ok { return {}, false }
	}
	if value, found := object["active"]; found {
		result.active, ok = value.(json.Boolean)
		if !ok { return {}, false }
	}
	return result, true
}

camera_3d_from_json :: proc(data: json.Value) -> (Camera3D, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }

	result := default_camera_3d()
	if value, found := object["target"]; found && !read_vector3(value, &result.target) { return {}, false }
	if value, found := object["up"]; found && !read_vector3(value, &result.up) { return {}, false }
	if value, found := object["fovy"]; found {
		result.fovy, ok = read_number(value)
		if !ok || result.fovy <= 0 { return {}, false }
	}
	if value, found := object["active"]; found {
		result.active, ok = value.(json.Boolean)
		if !ok { return {}, false }
	}
	return result, true
}

orbit_camera_3d_from_json :: proc(data: json.Value) -> (OrbitCamera3D, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }

	result := default_orbit_camera_3d()
	if value, found := object["target"]; found && !read_vector3(value, &result.target) { return {}, false }
	if value, found := object["yaw"]; found { result.yaw, ok = read_number(value); if !ok { return {}, false } }
	if value, found := object["pitch"]; found { result.pitch, ok = read_number(value); if !ok { return {}, false } }
	if value, found := object["distance"]; found { result.distance, ok = read_number(value); if !ok || result.distance <= 0 { return {}, false } }
	if value, found := object["min_pitch"]; found { result.min_pitch, ok = read_number(value); if !ok { return {}, false } }
	if value, found := object["max_pitch"]; found { result.max_pitch, ok = read_number(value); if !ok { return {}, false } }
	if value, found := object["min_distance"]; found { result.min_distance, ok = read_number(value); if !ok || result.min_distance <= 0 { return {}, false } }
	if value, found := object["max_distance"]; found { result.max_distance, ok = read_number(value); if !ok || result.max_distance <= 0 { return {}, false } }
	if value, found := object["auto_yaw_speed"]; found { result.auto_yaw_speed, ok = read_number(value); if !ok { return {}, false } }
	if value, found := object["orbit_sensitivity"]; found { result.orbit_sensitivity, ok = read_number(value); if !ok || result.orbit_sensitivity <= 0 { return {}, false } }
	if value, found := object["zoom_sensitivity"]; found { result.zoom_sensitivity, ok = read_number(value); if !ok || result.zoom_sensitivity <= 0 { return {}, false } }
	if value, found := object["manual_action"]; found { result.manual_action, ok = value.(json.String); if !ok { return {}, false } }
	if value, found := object["yaw_axis"]; found { result.yaw_axis, ok = value.(json.String); if !ok { return {}, false } }
	if value, found := object["pitch_axis"]; found { result.pitch_axis, ok = value.(json.String); if !ok { return {}, false } }
	if value, found := object["zoom_axis"]; found { result.zoom_axis, ok = value.(json.String); if !ok { return {}, false } }
	if result.min_pitch > result.max_pitch || result.min_distance > result.max_distance { return {}, false }
	result.pitch = clamp(result.pitch, result.min_pitch, result.max_pitch)
	result.distance = clamp(result.distance, result.min_distance, result.max_distance)
	return result, true
}

update_orbit_camera_3d :: proc(orbit: ^OrbitCamera3D, controls: ^input.Input, dt: f32) -> Transform {
	manual := len(orbit.manual_action) > 0 && input.is_down(controls, orbit.manual_action)
	if manual {
		if len(orbit.yaw_axis) > 0 {
			orbit.yaw -= input.axis(controls, orbit.yaw_axis) * orbit.orbit_sensitivity
		}
		if len(orbit.pitch_axis) > 0 {
			orbit.pitch += input.axis(controls, orbit.pitch_axis) * orbit.orbit_sensitivity
		}
	} else if orbit.auto_yaw_speed != 0 {
		orbit.yaw += orbit.auto_yaw_speed * dt
	}
	if len(orbit.zoom_axis) > 0 {
		orbit.distance -= input.axis(controls, orbit.zoom_axis) * orbit.zoom_sensitivity
	}
	orbit.pitch = clamp(orbit.pitch, orbit.min_pitch, orbit.max_pitch)
	orbit.distance = clamp(orbit.distance, orbit.min_distance, orbit.max_distance)
	for orbit.yaw >= 360 { orbit.yaw -= 360 }
	for orbit.yaw < 0 { orbit.yaw += 360 }

	yaw := orbit.yaw * f32(math.PI / 180)
	pitch := orbit.pitch * f32(math.PI / 180)
	horizontal_distance := orbit.distance * f32(math.cos(f64(pitch)))
	return Transform{
		position = {
			orbit.target[0] + horizontal_distance * f32(math.cos(f64(yaw))),
			orbit.target[1] + orbit.distance * f32(math.sin(f64(pitch))),
			orbit.target[2] + horizontal_distance * f32(math.sin(f64(yaw))),
		},
		scale = {1, 1, 1},
	}
}

clamp :: proc(value, minimum, maximum: f32) -> f32 {
	if value < minimum { return minimum }
	if value > maximum { return maximum }
	return value
}
