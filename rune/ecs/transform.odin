package ecs

import "core:encoding/json"
import "core:math/linalg"
import "rune:jsonutil"

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

// Child offsets inherit parent scale and then rotation. Euler angles retain
// additive composition, which is exact for rotations about a shared axis;
// arbitrary mixed-axis rotations and shear are not represented by Transform.
compose_transform_3d :: proc(parent, local: Transform) -> Transform {
	offset := local.position * parent.scale
	if parent.rotation != ([3]f32{}) {
		rotation := parent.rotation * Radians_Per_Degree
		orientation := linalg.quaternion_from_pitch_yaw_roll(rotation[0], rotation[1], rotation[2])
		offset = linalg.quaternion_mul_vector3(orientation, offset)
	}
	return Transform{
		position = parent.position + offset,
		rotation = parent.rotation + local.rotation,
		scale = parent.scale * local.scale,
	}
}

// Convert a world point into the local frame of this composed TRS transform.
// Mirrors compose_transform_3d's scale-then-rotate convention. Zero scale or
// non-finite inputs/results have no usable inverse and return false.
inverse_transform_point_3d :: proc(transform: Transform, point: [3]f32) -> ([3]f32,bool) {
	if !component_value_valid(transform) || !physics_query_vector_valid(point) {return {},false}
	for axis in transform.scale {if axis==0 {return {},false}}
	offset:=point-transform.position
	if transform.rotation!=([3]f32{}) {
		rotation:=transform.rotation*Radians_Per_Degree
		orientation:=linalg.quaternion_from_pitch_yaw_roll(rotation[0],rotation[1],rotation[2])
		offset=linalg.quaternion_mul_vector3(linalg.quaternion_inverse(orientation),offset)
	}
	local:=offset/transform.scale
	if !physics_query_vector_valid(local) {return {},false}
	return local,true
}

// Resolve from the root so rendering, picking and terrain/static collision
// use the same composition, including ancestors without a Transform.
world_transform_3d :: proc(world: ^World, entity: Entity) -> Transform {
	parent := default_transform()
	if ancestor := world.parents[entity]; ancestor != 0 {
		parent = world_transform_3d(world, ancestor)
	}
	if local, found := world.transforms[entity]; found {
		return compose_transform_3d(parent, local)
	}
	return parent
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

	return transform, component_value_valid(transform)
}

read_vector3 :: proc(data: json.Value, result: ^[3]f32) -> bool {
	array, array_ok := data.(json.Array)
	if !array_ok || len(array) != 3 {
		return false
	}

	for value, index in array {
		number, number_ok := read_number(value)
		if !number_ok {return false}
		result[index] = number
	}
	return true
}

read_number :: proc(data: json.Value) -> (f32, bool) {
	return jsonutil.number(data)
}
