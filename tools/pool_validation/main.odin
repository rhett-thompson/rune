package main

import "core:fmt"
import "core:mem"
import "rune:pool"

Owned :: struct {
	bytes: []u8,
}

cleanups: int

cleanup_owned :: proc(value: ^Owned) {
	delete(value.bytes)
	cleanups += 1
}

main :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_handles_and_reuse(&tracker)
	validate_growth_and_iteration()
	validate_cleanup()
	validate_allocation_failure()
	assert(tracker.current_memory_allocated == 0)
	assert(len(tracker.allocation_map) == 0)
	assert(len(tracker.bad_free_array) == 0)
	fmt.println("Pool validation passed: reuse, handles, growth, iteration, cleanup, and allocation ownership")
}

validate_handles_and_reuse :: proc(tracker: ^mem.Tracking_Allocator) {
	values: pool.Pool(int)
	_, uninitialized := pool.acquire(&values)
	assert(!uninitialized)
	assert(!pool.init(&values, -1))
	assert(pool.init(&values, 2))
	defer pool.destroy(&values)
	assert(!pool.init(&values, 2))
	first, ok := pool.acquire(&values, 42)
	assert(ok && pool.get(&values, first)^ == 42)
	second, second_ok := pool.acquire(&values, 17)
	assert(second_ok && pool.count(&values) == 2)
	_, full := pool.acquire(&values)
	assert(!full && pool.count(&values) == 2)
	assert(pool.get(&values, {}) == nil)
	other: pool.Pool(int)
	assert(pool.init(&other, 1))
	defer pool.destroy(&other)
	foreign_handle, foreign_ok := pool.acquire(&other, 9)
	assert(foreign_ok && pool.get(&values, foreign_handle) == nil)
	assert(!pool.release(&values, foreign_handle))
	assert(pool.release(&values, first))
	assert(!pool.release(&values, first))
	assert(pool.get(&values, first) == nil)
	allocations := tracker.total_allocation_count
	for _ in 0 ..< 10_000 {
		handle, acquired := pool.acquire(&values)
		assert(acquired && handle.index == first.index)
		assert(pool.get(&values, handle)^ == 0)
		pool.get(&values, handle)^ = 123
		assert(pool.get(&values, first) == nil)
		assert(pool.get(&values, second)^ == 17)
		assert(pool.release(&values, handle))
	}
	assert(tracker.total_allocation_count == allocations)
	pool.clear(&values)
	assert(pool.count(&values) == 0 && pool.capacity(&values) == 2)
	assert(pool.get(&values, second) == nil)
	pool.destroy(&values)
	pool.destroy(&values)
	assert(pool.init(&values, 2))
	reborn, reborn_ok := pool.acquire(&values, 1)
	assert(reborn_ok && reborn.owner != first.owner)
	assert(pool.get(&values, first) == nil && pool.get(&values, second) == nil)
}

validate_growth_and_iteration :: proc() {
	values: pool.Pool([2]int)
	assert(pool.init(&values, 1, .Double))
	defer pool.destroy(&values)
	first, ok := pool.acquire(&values, [2]int{1, 2})
	assert(ok)
	second, second_ok := pool.acquire(&values, [2]int{3, 4})
	assert(second_ok && pool.capacity(&values) == 2)
	assert(pool.release(&values, second))
	for index in 0 ..< 50 {
		_, acquired := pool.acquire(&values, [2]int{index, index + 1})
		assert(acquired)
	}
	assert(pool.get(&values, first)^ == [2]int{1, 2})
	assert(pool.reserve(&values, 128))
	assert(pool.capacity(&values) == 128)
	assert(pool.get(&values, first)^ == [2]int{1, 2})
	assert(!pool.reserve(&values, -1))
	assert(!pool.reserve(&values, max(int)))
	cursor, visited := 0, 0
	for {
		value, handle := pool.next(&values, &cursor)
		if value == nil {break}
		visited += 1
		assert(pool.release(&values, handle))
	}
	assert(visited == 51 && pool.count(&values) == 0)
	_, again := pool.acquire(&values)
	assert(again)
	pool.clear(&values)
	assert(pool.count(&values) == 0)
	// Empty growing and fixed pools have deliberate, different exhaustion rules.
	empty: pool.Pool(int)
	assert(pool.init(&empty, growth = .Double))
	_, grew := pool.acquire(&empty)
	assert(grew && pool.capacity(&empty) == 16)
	pool.destroy(&empty)
	assert(pool.init(&empty))
	_, fixed := pool.acquire(&empty)
	assert(!fixed)
	assert(pool.reserve(&empty, 1))
	_, reserved := pool.acquire(&empty)
	assert(reserved)
	pool.destroy(&empty)
}

validate_cleanup :: proc() {
	values: pool.Pool(Owned)
	assert(pool.init(&values, 1, .Double, cleanup_owned))
	first, ok := pool.acquire(&values, Owned{make([]u8, 8)})
	assert(ok)
	_, second_ok := pool.acquire(&values, Owned{make([]u8, 16)})
	assert(second_ok && cleanups == 0)
	assert(pool.release(&values, first) && cleanups == 1)
	assert(!pool.release(&values, first) && cleanups == 1)
	pool.clear(&values)
	assert(cleanups == 2)
	_, third_ok := pool.acquire(&values, Owned{make([]u8, 32)})
	assert(third_ok)
	pool.destroy(&values)
	pool.destroy(&values)
	assert(cleanups == 3)
}

Failing_Allocator :: struct {
	backing: mem.Allocator,
	fail: bool,
}

failing_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^Failing_Allocator)(data)
	if state.fail && (mode == .Alloc || mode == .Resize || mode == .Alloc_Non_Zeroed || mode == .Resize_Non_Zeroed) {
		return nil, .Out_Of_Memory
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

validate_allocation_failure :: proc() {
	state := Failing_Allocator{backing = context.allocator, fail = true}
	allocator := mem.Allocator{procedure = failing_allocator_proc, data = &state}
	values: pool.Pool(int)
	assert(!pool.init(&values, 2, allocator = allocator))
	state.fail = false
	assert(pool.init(&values, 2, .Double, allocator = allocator))
	first, first_ok := pool.acquire(&values, 12)
	second, second_ok := pool.acquire(&values, 34)
	assert(first_ok && second_ok)
	state.fail = true
	_, failed := pool.acquire(&values, 56)
	assert(!failed && !pool.reserve(&values, 8))
	assert(pool.count(&values) == 2 && pool.capacity(&values) == 2)
	assert(pool.get(&values, first)^ == 12 && pool.get(&values, second)^ == 34)
	assert(pool.release(&values, first))
	_, reused := pool.acquire(&values, 78)
	assert(reused)
	// Backing storage must be freed through the saved allocator, regardless of
	// the allocator in effect when the caller later destroys the pool.
	context.allocator = mem.panic_allocator()
	pool.destroy(&values)
	assert(!pool.init(&values, 1, allocator = mem.nil_allocator()))
}
