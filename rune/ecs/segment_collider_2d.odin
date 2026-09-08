package ecs

import "core:encoding/json"

// A zero-thickness edge, two-sided by default. One-way edges must be horizontal.
SegmentCollider2D :: struct {
	one_way: bool,
	start: [2]f32,
	end: [2]f32,
	offset: [2]f32,
	is_sensor: bool,
}

segment_collider_2d_from_json :: proc(data: json.Value) -> (SegmentCollider2D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result: SegmentCollider2D
	has_start, has_end := false, false
	for key, value in object {
		switch key {
		case "one_way": result.one_way, ok = value.(json.Boolean); if !ok {return {}, false}
		case "start": has_start = read_vector2(value, &result.start); if !has_start {return {}, false}
		case "end": has_end = read_vector2(value, &result.end); if !has_end {return {}, false}
		case "offset": if !read_vector2(value, &result.offset) {return {}, false}
		case "is_sensor": result.is_sensor, ok = value.(json.Boolean); if !ok {return {}, false}
		case: return {}, false
		}
	}
	return result, has_start && has_end && component_value_valid(result)
}

segment_points_valid_2d :: proc(a, b: [2]f32) -> bool {
	if !physics_query_vector_valid(a) || !physics_query_vector_valid(b) {return false}
	d := b - a
	length_squared := d[0]*d[0] + d[1]*d[1]
	// Box2D requires edges longer than linear slop (0.005 world units).
	return finite_nonnegative(length_squared) && length_squared > 0.005*0.005
}

get_segment_collider_2d :: proc(world: ^World, entity: Entity) -> (SegmentCollider2D, bool) {
	value, found := world.segment_colliders_2d[entity]
	return value, found
}

set_segment_collider_2d :: proc(world: ^World, entity: Entity, value: SegmentCollider2D) -> bool {
	if !has_component_data(world, entity, "SegmentCollider2D") || !component_value_valid(value) {return false}
	commit_component_value(world, entity, "SegmentCollider2D", &world.segment_colliders_2d, value)
	return true
}
