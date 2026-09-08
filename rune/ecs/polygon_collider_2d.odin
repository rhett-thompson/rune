package ecs

import "core:encoding/json"
import b2 "vendor:box2d"

// Vertices follow the perimeter in either winding, without a repeated closing
// vertex. Getters return borrowed storage; pass a separate slice to edit vertices.
// add/set copy the slice, so code-first callers retain ownership of their input.
PolygonCollider2D :: struct {
	vertices: [][2]f32,
	offset: [2]f32,
	is_sensor: bool,
}

// Like other JSON readers, the returned scratch data lasts until temp reset.
polygon_collider_2d_from_json :: proc(data: json.Value) -> (PolygonCollider2D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result: PolygonCollider2D
	for key, value in object {
		switch key {
		case "vertices":
			array, valid := value.(json.Array)
			if !valid || len(array) < 3 || len(array) > b2.MAX_POLYGON_VERTICES {return {}, false}
			result.vertices = make([][2]f32, len(array), context.temp_allocator)
			for point, i in array {if !read_vector2(point, &result.vertices[i]) {return {}, false}}
		case "offset": if !read_vector2(value, &result.offset) {return {}, false}
		case "is_sensor": result.is_sensor, ok = value.(json.Boolean); if !ok {return {}, false}
		case: return {}, false
		}
	}
	return result, component_value_valid(result)
}

// Test every vertex against every edge, rejecting crossed perimeter order as
// well as concavity, duplicate points and collinear edges. Double precision
// keeps the cross products finite for finite f32 authoring coordinates.
polygon_vertices_valid_2d :: proc(vertices: [][2]f32) -> bool {
	if len(vertices) < 3 || len(vertices) > b2.MAX_POLYGON_VERTICES {return false}
	for point in vertices {if !physics_query_vector_valid(point) {return false}}
	winding: f64
	for a, i in vertices {
		j := (i + 1) % len(vertices)
		b := vertices[j]
		for p, k in vertices {
			if k == i || k == j {continue}
			cross := (f64(b[0])-f64(a[0]))*(f64(p[1])-f64(a[1])) -
			         (f64(b[1])-f64(a[1]))*(f64(p[0])-f64(a[0]))
			if cross == 0 {return false}
			if winding == 0 {winding = cross}
			if (cross > 0) != (winding > 0) {return false}
		}
	}
	_, ok := polygon_hull_2d(vertices)
	return ok
}

// ComputeHull may weld short edges. Require every vertex to survive rather
// than silently changing authored geometry, and never pass an invalid hull on.
polygon_hull_2d :: proc(vertices: [][2]f32) -> (b2.Hull, bool) {
	if len(vertices) < 3 || len(vertices) > b2.MAX_POLYGON_VERTICES {return {}, false}
	points: [b2.MAX_POLYGON_VERTICES]b2.Vec2
	for p, i in vertices {
		if !physics_query_vector_valid(p) {return {}, false}
		points[i] = {p[0], p[1]}
	}
	hull := b2.ComputeHull(points[:len(vertices)])
	return hull, int(hull.count) == len(vertices) && b2.ValidateHull(hull)
}

get_polygon_collider_2d :: proc(world: ^World, entity: Entity) -> (PolygonCollider2D, bool) {
	value, found := world.polygon_colliders_2d[entity]
	return value, found
}

set_polygon_collider_2d :: proc(world: ^World, entity: Entity, value: PolygonCollider2D) -> bool {
	if !has_component_data(world, entity, "PolygonCollider2D") || !component_value_valid(value) {return false}
	commit_component_value(world, entity, "PolygonCollider2D", &world.polygon_colliders_2d, value)
	return true
}

polygon_colliders_equal_2d :: proc(a, b: PolygonCollider2D) -> bool {
	if a.offset != b.offset || a.is_sensor != b.is_sensor || len(a.vertices) != len(b.vertices) {return false}
	for p, i in a.vertices {if p != b.vertices[i] {return false}}
	return true
}

// Physics uses local scale and translation, independent of visual parenting
// and Transform.rotation. Both shapes and gizmos share this conversion.
collider_point_2d :: proc(transform: Transform, point, offset: [2]f32) -> [2]f32 {
	return collider_center_2d(transform, point + offset)
}
