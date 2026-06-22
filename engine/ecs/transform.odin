package ecs

import "core:encoding/json"

// Transform is the typed built-in spatial component. JSON scenes use the same
// position, rotation, and scale fields, each represented by three numbers.
Transform :: struct {
	position: [3]f32,
	rotation: [3]f32,
	scale:    [3]f32,
}

default_transform :: proc() -> Transform {
	return Transform{scale = {1, 1, 1}}
}

transform_from_json :: proc(data: json.Value) -> (Transform, bool) {
	object, object_ok := data.(json.Object)
	if !object_ok {
		return {}, false
	}

	transform := default_transform()
	position, position_ok := object["position"]
	if position_ok && !read_vector3(position, &transform.position) {
		return {}, false
	}
	rotation, rotation_ok := object["rotation"]
	if rotation_ok && !read_vector3(rotation, &transform.rotation) {
		return {}, false
	}
	scale, scale_ok := object["scale"]
	if scale_ok && !read_vector3(scale, &transform.scale) {
		return {}, false
	}

	return transform, true
}

read_vector3 :: proc(data: json.Value, result: ^[3]f32) -> bool {
	array, array_ok := data.(json.Array)
	if !array_ok || len(array) != 3 {
		return false
	}

	for value, index in array {
		number, number_ok := read_number(value)
		if !number_ok { return false }
		result[index] = number
	}
	return true
}

read_number :: proc(data: json.Value) -> (f32, bool) {
	#partial switch number in data {
	case json.Integer: return f32(number), true
	case json.Float:   return f32(number), true
	}
	return 0, false
}
