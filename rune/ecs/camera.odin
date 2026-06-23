package ecs

import "core:encoding/json"

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

default_camera_2d :: proc() -> Camera2D {
	return Camera2D{zoom = 1}
}

default_camera_3d :: proc() -> Camera3D {
	return Camera3D{target = {0, 0, 0}, up = {0, 1, 0}, fovy = 45}
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
