package main

import "core:mem"
import "core:slice"
import "rune:ecs"

owned_overlap_size :: proc(world: ^ecs.World, d: int, entity: ecs.Entity, box: bool) -> i64 {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)
	// The caller allocator differs from both context allocators, so these also
	// catch an accidental fallback to the heap or frame scratch in a callback.
	empty := overlap(world, d, {-100, 0, 0}, 0.1, box = box, allocator = allocator)
	assert(len(empty) == 0)
	delete(empty, allocator)
	assert(tracker.total_memory_allocated == 0, "no-hit overlaps allocate no result storage")
	filtered := overlap(world, d, {}, 0.1, {layers = 2}, box, allocator)
	assert(len(filtered) == 0)
	delete(filtered, allocator)
	assert(tracker.total_memory_allocated == 0, "filtered-out overlaps allocate no result storage")

	first := overlap(world, d, {}, 0.1, box = box, allocator = allocator)
	assert(len(first) == 1 && first[0] == entity, "multiple shape hits deduplicate")
	allocated := tracker.current_memory_allocated
	assert(allocated > 0 && len(tracker.allocation_map) == 1, "result belongs to caller allocator")
	second := overlap(world, d, {}, 0.1, box = box, allocator = allocator)
	assert(len(second) == 1 && second[0] == entity && first[0] == entity)
	assert(raw_data(first) != raw_data(second), "owned query results remain independent")
	delete(first, allocator)
	delete(second, allocator)
	assert(tracker.current_memory_allocated == 0 && len(tracker.allocation_map) == 0)
	assert(len(tracker.bad_free_array) == 0)
	return allocated
}

validate_overlap_allocations :: proc(registry: ^ecs.Component_Registry, d: int) {
	world := ecs.init()
	defer ecs.destroy(&world)
	entity := body(&world, registry, d, 0, false, false)
	add(&world, registry, entity, round_name(d), `{"radius":1}`)
	before: [2]i64
	for box in 0 ..< 2 {before[box] = owned_overlap_size(&world, d, entity, box == 1)}
	for i in 0 ..< 512 {_ = body(&world, registry, d, f32(1000 + i*4), false, false)}
	for box in 0 ..< 2 {
		after := owned_overlap_size(&world, d, entity, box == 1)
		assert(after == before[box] && after <= 128,
			"local overlap allocation must not grow with unrelated world shapes")
	}

	// Exercise several buffer growth steps and preserve sorted unique results.
	expected: [65]ecs.Entity
	expected[0] = entity
	for i in 1 ..< len(expected) {expected[i] = body(&world, registry, d, f32(i*2), false, false)}
	slice.sort(expected[:])
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)
	for box in 0 ..< 2 {
		hits := overlap(&world, d, {}, 256, box = box == 1, allocator = allocator)
		assert(len(hits) == len(expected), "growing result storage must not drop hits")
		for hit, i in hits {assert(hit == expected[i], "overlap results remain sorted and unique")}
		delete(hits, allocator)
		assert(tracker.current_memory_allocated == 0 && len(tracker.allocation_map) == 0)
	}
	assert(len(tracker.bad_free_array) == 0)
}
