package ecs

import "base:runtime"
import "core:c"
import "core:mem"
import b3 "vendor:box3d"

Raycast_Hit_3D :: struct {
	entity:        Entity,
	component:     string,
	point, normal: [3]f32,
	fraction:      f32,
}

Physics_Query_3D :: struct {
	caller_context: runtime.Context,
	world:          ^World,
	filter:         Physics_Query_Filter,
	hit:            Raycast_Hit_3D,
	found:          bool,
	entities:       []Entity,
	count:          int,
}

// Translation is the complete segment, not a normalized direction.
// Queries synchronize new/rebuilt bodies without advancing simulation.
physics_3d_raycast :: proc(
	world: ^World,
	origin, translation: [3]f32,
	filter := Default_Physics_Query_Filter,
) -> (
	Raycast_Hit_3D,
	bool,
) {
	if !physics_query_vector_valid(origin) ||
	   !physics_query_vector_valid(translation) ||
	   translation == ([3]f32{}) ||
	   filter.layers == 0 {return {}, false}
	ensure_box3d_world(world)
	if world.physics_3d.needs_sync {sync_bodies_to_box3d(world)}
	query := Physics_Query_3D {
		caller_context = context,
		world          = world,
		filter         = filter,
	}
	_ = b3.World_CastRay(
		world.box3d_world,
		{origin[0], origin[1], origin[2]},
		{translation[0], translation[1], translation[2]},
		{categoryBits = filter.layers, maskBits = filter.layers},
		physics_3d_ray_result,
		&query,
	)
	return query.hit, query.found
}

physics_3d_ray_result :: proc "c" (
	shape: b3.ShapeId,
	point: b3.Pos,
	normal: b3.Vec3,
	fraction: f32,
	user_material: u64,
	triangle, child: c.int,
	ctx: rawptr,
) -> f32 {
	query := cast(^Physics_Query_3D)ctx
	context = query.caller_context
	owner, found := physics_3d_entity_from_shape(query.world, shape)
	if !found ||
	   owner.entity == query.filter.ignore ||
	   (!query.filter.include_sensors && b3.Shape_IsSensor(shape)) {return -1}
	if !query.found || fraction < query.hit.fraction {
		query.hit = {
			owner.entity,
			owner.component,
			{f32(point.x), f32(point.y), f32(point.z)},
			{f32(normal.x), f32(normal.y), f32(normal.z)},
			fraction,
		}
		query.found = true
	}
	return query.hit.fraction
}

physics_3d_overlap_result :: proc "c" (shape: b3.ShapeId, ctx: rawptr) -> bool {
	query := cast(^Physics_Query_3D)ctx
	context = query.caller_context
	owner, found := physics_3d_entity_from_shape(query.world, shape)
	if !found ||
	   owner.entity == query.filter.ignore ||
	   (!query.filter.include_sensors && b3.Shape_IsSensor(shape)) {return true}
	if query.count < len(query.entities) {
		query.entities[query.count] = owner.entity
		query.count += 1
	}
	return true
}

// Exact axis-aligned box overlap against native shapes. Results are sorted,
// unique entities allocated with allocator (frame scratch by default).
physics_3d_overlap_box :: proc(
	world: ^World,
	center, half_size: [3]f32,
	filter := Default_Physics_Query_Filter,
	allocator := context.temp_allocator,
) -> []Entity {
	if !physics_query_vector_valid(center) || !physics_query_vector_valid(half_size) {return nil}
	for extent in half_size {if extent <= 0 {return nil}}
	points: [8]b3.Vec3
	for i in 0 ..< 8 {
		points[i] = {
			half_size[0] * (1 if i & 1 != 0 else -1),
			half_size[1] * (1 if i & 2 != 0 else -1),
			half_size[2] * (1 if i & 4 != 0 else -1),
		}
	}
	proxy := b3.ShapeProxy {
		points = raw_data(points[:]),
		count  = 8,
	}
	return physics_3d_overlap_proxy(world, center, proxy, filter, allocator)
}

physics_3d_overlap_sphere :: proc(
	world: ^World,
	center: [3]f32,
	radius: f32,
	filter := Default_Physics_Query_Filter,
	allocator := context.temp_allocator,
) -> []Entity {
	if !physics_query_vector_valid(center) ||
	   !finite_nonnegative(radius) ||
	   radius == 0 {return nil}
	point := b3.Vec3{}
	proxy := b3.ShapeProxy {
		points = &point,
		count  = 1,
		radius = radius,
	}
	return physics_3d_overlap_proxy(world, center, proxy, filter, allocator)
}

physics_3d_overlap_proxy :: proc(
	world: ^World,
	center: [3]f32,
	proxy: b3.ShapeProxy,
	filter: Physics_Query_Filter,
	allocator: mem.Allocator,
) -> []Entity {
	if filter.layers == 0 {return nil}
	ensure_box3d_world(world)
	if world.physics_3d.needs_sync {sync_bodies_to_box3d(world)}
	query := Physics_Query_3D {
		caller_context = context,
		world          = world,
		filter         = filter,
		entities       = make([]Entity, len(world.physics_3d.shapes), allocator),
	}
	_ = b3.World_OverlapShape(
		world.box3d_world,
		{center[0], center[1], center[2]},
		proxy,
		{categoryBits = filter.layers, maskBits = filter.layers},
		physics_3d_overlap_result,
		&query,
	)
	return physics_query_entities(query.entities[:query.count])
}
