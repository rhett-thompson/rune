// Package pool provides reusable storage for code-owned values. It has no
// dependency on ECS, scenes, or raylib.
package pool

import "core:mem"
import "core:sync"

Growth :: enum {
	Fixed,  // acquire fails when full; reserve may still explicitly add capacity.
	Double, // acquire doubles capacity when full (starting at 16).
}

Handle :: struct {
	owner:      u64,
	generation: u64,
	index:      int,
}

@(private)
Slot :: struct($T: typeid) {
	value:      T,
	generation: u64,
	next_free:  int,
	active:     bool,
}

// Treat fields as implementation details. A Pool owns its storage: do not copy
// an initialized Pool. Values must tolerate relocation when capacity grows.
Pool :: struct($T: typeid) {
	slots:     []Slot(T),
	allocator: mem.Allocator,
	cleanup:   proc(value: ^T),
	growth:    Growth,
	owner:     u64,
	free_head: int,
	live:      int,
}

@(private)
next_owner: u64 = 1

// init requires a zero/destroyed Pool. cleanup, if supplied, runs once for each
// active value on release, clear, or destroy; it must not mutate this Pool.
init :: proc(
	pool: ^Pool($T),
	initial_capacity: int = 0,
	growth: Growth = .Fixed,
	cleanup: proc(value: ^T) = nil,
	allocator := context.allocator,
) -> bool {
	if pool == nil || pool.owner != 0 || initial_capacity < 0 {return false}
	owner := sync.atomic_add(&next_owner, 1)
	assert(owner != 0, "pool identity exhausted")
	pool^ = {allocator = allocator, cleanup = cleanup, growth = growth, owner = owner, free_head = -1}
	if !reserve(pool, initial_capacity) {
		pool^ = {}
		return false
	}
	return true
}

count :: proc(pool: ^Pool($T)) -> int {
	return 0 if pool == nil else pool.live
}

capacity :: proc(pool: ^Pool($T)) -> int {
	return 0 if pool == nil else len(pool.slots)
}

// reserve preserves handles and values, but successful growth invalidates all
// borrowed pointers. Failure leaves existing storage and handles unchanged.
reserve :: proc(pool: ^Pool($T), requested: int) -> bool {
	if pool == nil || pool.owner == 0 || requested < 0 {return false}
	previous := len(pool.slots)
	if requested <= previous {return true}
	if requested > max(int) / size_of(Slot(T)) {return false}
	slots, err := make([]Slot(T), requested, pool.allocator)
	if err != nil || raw_data(slots) == nil {return false}
	copy(slots, pool.slots)
	for index in previous ..< requested {
		slots[index].generation = 1
		slots[index].next_free = index + 1
	}
	slots[requested - 1].next_free = pool.free_head
	delete(pool.slots, pool.allocator)
	pool.slots = slots
	pool.free_head = previous
	return true
}

// acquire shallow-copies value (zero by default). On success the caller hands
// any owned resources to the pool's cleanup callback; on failure it retains them.
// Acquire/release do not allocate when a free slot is available.
acquire :: proc{acquire_value, acquire_zero}

@(private)
acquire_zero :: proc(pool: ^Pool($T)) -> (Handle, bool) {
	value: T
	return acquire_value(pool, value)
}

@(private)
acquire_value :: proc(pool: ^Pool($T), value: T) -> (Handle, bool) {
	if pool == nil || pool.owner == 0 {return {}, false}
	if pool.free_head < 0 {
		if pool.growth == .Fixed {return {}, false}
		previous := len(pool.slots)
		if previous > max(int) / 2 {return {}, false}
		target := 16 if previous == 0 else previous * 2
		if !reserve(pool, target) {return {}, false}
	}
	index := pool.free_head
	slot := &pool.slots[index]
	pool.free_head = slot.next_free
	slot.value = value
	slot.active = true
	slot.next_free = -1
	pool.live += 1
	return Handle{pool.owner, slot.generation, index}, true
}

// get returns a borrowed pointer, or nil for invalid, released, or foreign
// handles. Keep handles across growth, never pointers.
get :: proc(pool: ^Pool($T), handle: Handle) -> ^T {
	if pool == nil || pool.owner == 0 || handle.owner != pool.owner ||
	   handle.index < 0 || handle.index >= len(pool.slots) {return nil}
	slot := &pool.slots[handle.index]
	if !slot.active || slot.generation != handle.generation {return nil}
	return &slot.value
}

release :: proc(pool: ^Pool($T), handle: Handle) -> bool {
	value := get(pool, handle)
	if value == nil {return false}
	if pool.cleanup != nil {pool.cleanup(value)}
	slot := &pool.slots[handle.index]
	slot.value = {}
	slot.active = false
	pool.live -= 1
	// Retire a slot instead of wrapping its generation and reviving old handles.
	if slot.generation != max(u64) {
		slot.generation += 1
		slot.next_free = pool.free_head
		pool.free_head = handle.index
	}
	return true
}

// next scans occupied slots without allocating. Start cursor at zero; nil means
// the end. Releasing the returned handle is safe. Do not acquire, reserve, clear,
// or destroy this pool during iteration. A full traversal is O(capacity).
next :: proc(pool: ^Pool($T), cursor: ^int) -> (^T, Handle) {
	if pool == nil || pool.owner == 0 || cursor == nil || cursor^ < 0 {return nil, {}}
	for cursor^ < len(pool.slots) {
		index := cursor^
		cursor^ += 1
		slot := &pool.slots[index]
		if slot.active {return &slot.value, Handle{pool.owner, slot.generation, index}}
	}
	return nil, {}
}

// clear releases live values and invalidates their handles, retaining capacity.
clear :: proc(pool: ^Pool($T)) {
	cursor := 0
	for {
		value, handle := next(pool, &cursor)
		if value == nil {break}
		release(pool, handle)
	}
}

// destroy releases live values and backing storage. Repeated calls are safe.
destroy :: proc(pool: ^Pool($T)) {
	if pool == nil || pool.owner == 0 {return}
	clear(pool)
	delete(pool.slots, pool.allocator)
	pool^ = {}
}
