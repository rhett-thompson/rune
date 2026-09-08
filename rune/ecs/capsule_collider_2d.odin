package ecs

import "core:encoding/json"
import "core:math"

Capsule_Axis_2D :: enum {vertical, horizontal}

// Height is the full tip-to-tip length along axis, including both round caps.
CapsuleCollider2D :: struct {
	radius: f32,
	height: f32,
	axis: Capsule_Axis_2D,
	offset: [2]f32,
	is_sensor: bool,
}

default_capsule_collider_2d :: proc() -> CapsuleCollider2D {
	return {radius = 8, height = 32, axis = .vertical}
}

capsule_collider_2d_from_json :: proc(data: json.Value) -> (CapsuleCollider2D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := default_capsule_collider_2d()
	for key, value in object {
		switch key {
		case "radius": result.radius, ok = read_number(value); if !ok {return {}, false}
		case "height": result.height, ok = read_number(value); if !ok {return {}, false}
		case "offset": if !read_vector2(value, &result.offset) {return {}, false}
		case "is_sensor": result.is_sensor, ok = value.(json.Boolean); if !ok {return {}, false}
		case "axis":
			axis, valid := value.(json.String)
			if !valid {return {}, false}
			switch axis {
			case "vertical": result.axis = .vertical
			case "horizontal": result.axis = .horizontal
			case: return {}, false
			}
		case: return {}, false
		}
	}
	return result, component_value_valid(result)
}

get_capsule_collider_2d :: proc(world: ^World, entity: Entity) -> (CapsuleCollider2D, bool) {
	value, found := world.capsule_colliders_2d[entity]
	return value, found
}

set_capsule_collider_2d :: proc(world: ^World, entity: Entity, value: CapsuleCollider2D) -> bool {
	if !has_component_data(world, entity, "CapsuleCollider2D") || !component_value_valid(value) {return false}
	commit_component_value(world, entity, "CapsuleCollider2D", &world.capsule_colliders_2d, value)
	return true
}

// Shared by native shape creation and gizmos. Physics uses the entity's own
// Transform and remains axis-aligned; parent transforms and rotation are visual.
collider_offset_2d :: proc(transform: Transform, offset: [2]f32) -> [2]f32 {
	return offset * [2]f32{transform.scale[0], transform.scale[1]}
}

collider_center_2d :: proc(transform: Transform, offset: [2]f32) -> [2]f32 {
	return [2]f32{transform.position[0], transform.position[1]} + collider_offset_2d(transform, offset)
}

collider_radius_scale_2d :: proc(transform: Transform) -> f32 {
	return max(math.abs(transform.scale[0]), math.abs(transform.scale[1]))
}

capsule_collider_2d_geometry :: proc(collider: CapsuleCollider2D, transform: Transform) -> (a, b: [2]f32, radius: f32) {
	center := collider_center_2d(transform, collider.offset)
	delta: [2]f32
	axis := 1 if collider.axis == .vertical else 0
	delta[axis] = (collider.height * 0.5 - collider.radius) * transform.scale[axis]
	return center - delta, center + delta, collider.radius * collider_radius_scale_2d(transform)
}
