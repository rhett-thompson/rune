package main

import "core:mem"
import "core:slice"
import "rune:ecs"

Query_Marker :: struct {value: i32}
Query_Unregistered :: struct {value: i32}

assert_query_entities :: proc(actual, expected: []ecs.Entity) {
	slice.sort(actual)
	assert(len(actual) == len(expected), "query membership count")
	for entity, i in actual {assert(entity == expected[i], "query membership")}
}

query_allocation_sizes :: proc(w: ^ecs.World, expected: ecs.Entity) -> [2]i64 {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)
	context.temp_allocator = allocator
	sizes: [2]i64
	for third in 0 ..< 2 {
		before := tracker.total_memory_allocated
		allocations := tracker.total_allocation_count
		entities := ecs.query2(w, ecs.Transform, Query_Marker) if third == 0 else
			ecs.query3(w, ecs.Transform, ecs.Lifetime, Query_Marker)
		assert_query_entities(entities, []ecs.Entity{expected})
		sizes[third] = tracker.total_memory_allocated - before
		assert(tracker.total_allocation_count - allocations <= 1, "queries need only their result allocation")
		delete(entities, allocator)
		assert(tracker.current_memory_allocated == 0 && len(tracker.allocation_map) == 0)
	}
	assert(len(tracker.bad_free_array) == 0)
	return sizes
}

validate_queries :: proc(r: ^ecs.Component_Registry) {
	assert(ecs.register_component_type(r, "QueryMarker", Query_Marker, Query_Marker{}))
	w := ecs.init()
	defer ecs.destroy(&w)
	parent := ecs.create_entity(&w)
	matching: [2]ecs.Entity
	for i in 0 ..< 16 {
		e := ecs.create_entity(&w)
		assert(ecs.add(&w, r, e, ecs.default_transform()))
		if i < 8 {assert(ecs.add(&w, r, e, ecs.Lifetime{100}))}
		if i < 2 {
			matching[i] = e
			assert(ecs.add(&w, r, e, Query_Marker{i32(i)}))
		}
	}
	marker_only := ecs.create_entity(&w)
	assert(ecs.add(&w, r, marker_only, Query_Marker{}))
	assert(ecs.set_parent(&w, matching[1], parent))
	assert(ecs.set_enabled(&w, parent, false))
	assert(ecs.is_locally_enabled(&w, matching[1]))
	expected := []ecs.Entity{matching[0]}
	assert_query_entities(ecs.query2(&w, ecs.Transform, Query_Marker), expected)
	assert_query_entities(ecs.query2(&w, Query_Marker, ecs.Transform), expected)
	// Exercise the smallest set in every argument position.
	assert_query_entities(ecs.query3(&w, Query_Marker, ecs.Transform, ecs.Lifetime), expected)
	assert_query_entities(ecs.query3(&w, ecs.Transform, Query_Marker, ecs.Lifetime), expected)
	assert_query_entities(ecs.query3(&w, ecs.Transform, ecs.Lifetime, Query_Marker), expected)
	assert_query_entities(ecs.query3(&w, ecs.Lifetime, ecs.Transform, Query_Marker), expected)
	assert_query_entities(ecs.query2(&w, ecs.Transform, Query_Marker, include_disabled = true), matching[:])
	assert_query_entities(ecs.query3(&w, ecs.Lifetime, Query_Marker, ecs.Transform, include_disabled = true), matching[:])
	assert_query_entities(ecs.query3(&w, Query_Marker, Query_Marker, ecs.Transform), expected)
	assert(len(ecs.query2(&w, ecs.Transform, Query_Unregistered)) == 0)
	assert(len(ecs.query3(&w, ecs.Transform, Query_Marker, Query_Unregistered)) == 0)
	// Reject entities missing either of the other memberships, not only those
	// missing both. Swapping the driving map must keep both intersection tests.
	assert(ecs.add(&w, r, marker_only, ecs.default_transform()))
	assert_query_entities(ecs.query3(&w, ecs.Transform, Query_Marker, ecs.Lifetime), expected)
	assert_query_entities(ecs.query3(&w, ecs.Lifetime, ecs.Transform, Query_Marker), expected)
	assert(ecs.remove_component(&w, marker_only, "Transform"))
	assert(ecs.add(&w, r, marker_only, ecs.Lifetime{100}))
	assert_query_entities(ecs.query3(&w, ecs.Transform, ecs.Lifetime, Query_Marker), expected)
	assert_query_entities(ecs.query3(&w, Query_Marker, ecs.Lifetime, ecs.Transform), expected)
	assert(ecs.remove_component(&w, marker_only, "Lifetime"))

	// Named multi-instance components still contribute one entity, not one hit
	// per instance, regardless of which membership map drives the query.
	add(&w, r, matching[0], "AudioPlayer", `{"first":{"sound":"one.wav"},"second":{"sound":"two.wav"}}`)
	assert_query_entities(ecs.query2(&w, ecs.Transform, ecs.AudioPlayer), expected)
	assert_query_entities(ecs.query3(&w, Query_Marker, ecs.AudioPlayer, ecs.Transform), expected)

	before := query_allocation_sizes(&w, matching[0])
	for _ in 0 ..< 1024 {
		e := ecs.create_entity(&w)
		assert(ecs.add(&w, r, e, ecs.default_transform()))
	}
	after := query_allocation_sizes(&w, matching[0])
	assert(before == after && after[0] <= 128 && after[1] <= 128,
		"query scratch scales with the smallest membership, not unrelated Transforms")

	assert(ecs.set_enabled(&w, matching[0], false))
	assert(len(ecs.query3(&w, ecs.Transform, ecs.Lifetime, Query_Marker)) == 0)
	assert_query_entities(ecs.query3(&w, ecs.Transform, ecs.Lifetime, Query_Marker, include_disabled = true), matching[:])
	assert(ecs.remove_component(&w, matching[0], "QueryMarker"))
	assert_query_entities(ecs.query2(&w, ecs.Transform, Query_Marker, include_disabled = true), matching[1:])
	assert(ecs.remove_component(&w, matching[1], "QueryMarker"))
	assert(len(ecs.query2(&w, ecs.Transform, Query_Marker, include_disabled = true)) == 0)
	assert(ecs.remove_component(&w, marker_only, "QueryMarker"))
	assert(len(ecs.query3(&w, ecs.Transform, ecs.Lifetime, Query_Marker)) == 0)
}
