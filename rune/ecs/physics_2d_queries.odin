package ecs

import "base:runtime"
import "core:mem"
import b2 "vendor:box2d"

Raycast_Hit_2D :: struct {
	entity:        Entity,
	component:     string,
	point, normal: [2]f32,
	fraction:      f32,
}

Physics_Query_2D :: struct {
	caller_context: runtime.Context,
	world:          ^World,
	filter:         Physics_Query_Filter,
	hit:            Raycast_Hit_2D,
	found:          bool,
	entities:       []Entity,
	count:          int,
	respect_one_way: bool,
}

// Translation is the complete segment, not a normalized direction.
// Queries synchronize new/rebuilt bodies without advancing simulation.
physics_2d_raycast :: proc(
	world: ^World,
	origin, translation: [2]f32,
	filter := Default_Physics_Query_Filter,
) -> (
	Raycast_Hit_2D,
	bool,
) {
	if !physics_query_vector_valid(origin) ||
	   !physics_query_vector_valid(translation) ||
	   translation == ([2]f32{}) ||
	   filter.layers == 0 {return {}, false}
	ensure_box2d_world(world)
	if world.physics_2d.needs_sync {sync_bodies_to_box2d(world, apply_velocities = false)}
	query := Physics_Query_2D {
		caller_context = context,
		world          = world,
		filter         = filter,
	}
	_ = b2.World_CastRay(
		world.box2d_world,
		{origin[0], origin[1]},
		{translation[0], translation[1]},
		{categoryBits = filter.layers, maskBits = filter.layers},
		physics_2d_ray_result,
		&query,
	)
	return query.hit, query.found
}

physics_2d_ray_result :: proc "c" (
	shape: b2.ShapeId,
	point: b2.Vec2,
	normal: b2.Vec2,
	fraction: f32,
	ctx: rawptr,
) -> f32 {
	query := cast(^Physics_Query_2D)ctx
	context = query.caller_context
	owner, found := physics_2d_entity_from_shape(query.world, shape)
	if !found ||
	   owner.entity == query.filter.ignore ||
	   (!query.filter.include_sensors && b2.Shape_IsSensor(shape)) {return -1}
	if query.respect_one_way && !one_way_cast_2d(query.world,query.filter.ignore,shape,normal) {return -1}
	if !query.found || fraction < query.hit.fraction {
		query.hit = {
			owner.entity,
			owner.component,
			{f32(point.x), f32(point.y)},
			{f32(normal.x), f32(normal.y)},
			fraction,
		}
		query.found = true
	}
	return query.hit.fraction
}

physics_2d_overlap_result :: proc "c" (shape: b2.ShapeId, ctx: rawptr) -> bool {
	query := cast(^Physics_Query_2D)ctx
	context = query.caller_context
	owner, found := physics_2d_entity_from_shape(query.world, shape)
	if !found ||
	   owner.entity == query.filter.ignore ||
	   (!query.filter.include_sensors && b2.Shape_IsSensor(shape)) {return true}
	if query.count < len(query.entities) {
		query.entities[query.count] = owner.entity
		query.count += 1
	}
	return true
}

// Exact axis-aligned box overlap against native shapes. Results are sorted,
// unique entities allocated with allocator (frame scratch by default).
physics_2d_overlap_box :: proc(
	world: ^World,
	center, half_size: [2]f32,
	filter := Default_Physics_Query_Filter,
	allocator := context.temp_allocator,
) -> []Entity {
	if !physics_query_vector_valid(center) || !physics_query_vector_valid(half_size) {return nil}
	for extent in half_size {if extent <= 0 {return nil}}
	points := [4]b2.Vec2 {
		{center[0] - half_size[0], center[1] - half_size[1]},
		{center[0] + half_size[0], center[1] - half_size[1]},
		{center[0] + half_size[0], center[1] + half_size[1]},
		{center[0] - half_size[0], center[1] + half_size[1]},
	}
	proxy := b2.MakeProxy(points[:], 0)
	return physics_2d_overlap_proxy(world, proxy, filter, allocator)
}

physics_2d_overlap_circle :: proc(
	world: ^World,
	center: [2]f32,
	radius: f32,
	filter := Default_Physics_Query_Filter,
	allocator := context.temp_allocator,
) -> []Entity {
	if !physics_query_vector_valid(center) ||
	   !finite_nonnegative(radius) ||
	   radius == 0 {return nil}
	points := [1]b2.Vec2{{center[0], center[1]}}
	proxy := b2.MakeProxy(points[:], radius)
	return physics_2d_overlap_proxy(world, proxy, filter, allocator)
}

physics_2d_overlap_proxy :: proc(
	world: ^World,
	proxy: b2.ShapeProxy,
	filter: Physics_Query_Filter,
	allocator: mem.Allocator,
) -> []Entity {
	if filter.layers == 0 {return nil}
	ensure_box2d_world(world)
	if world.physics_2d.needs_sync {sync_bodies_to_box2d(world, apply_velocities = false)}
	query := Physics_Query_2D {
		caller_context = context,
		world          = world,
		filter         = filter,
		entities       = make([]Entity, len(world.physics_2d.shapes), allocator),
	}
	_ = b2.World_OverlapShape(
		world.box2d_world,
		proxy,
		{categoryBits = filter.layers, maskBits = filter.layers},
		physics_2d_overlap_result,
		&query,
	)
	return physics_query_entities(query.entities[:query.count])
}
