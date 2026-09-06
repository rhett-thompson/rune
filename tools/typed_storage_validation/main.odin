package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "rune:ecs"

Plain :: struct {
	count: i32,
	position: [3]f32,
	nested: struct {active: bool},
}

Owned :: struct {
	label: string,
	names: []string,
	values: [dynamic]i32,
	weights: map[string]f32,
	nested: struct {text: string},
}

Tagged :: struct {
	count: i32 `json:"amount"`,
	ignored: i32 `json:"-"`,
}

main :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	// Frame scratch is separate from the heap whose live allocations we check.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_updates(&tracker)
	validate_reload(&tracker)
	assert(len(tracker.bad_free_array) == 0)
	assert(tracker.current_memory_allocated == 0)
	assert(len(tracker.allocation_map) == 0)
	fmt.println("Typed storage: allocation-free plain updates, bounded owned updates, reload and cleanup passed")
}

parse :: proc(text: string) -> json.Value {
	value: json.Value
	err := json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator)
	assert(err == nil, fmt.tprintf("%s: %v", text, err))
	return value
}

registry :: proc() -> ecs.Component_Registry {
	result := ecs.init_registry()
	assert(ecs.register_component_type(&result, "Plain", Plain, Plain{}))
	assert(ecs.register_component_type(&result, "Owned", Owned, Owned{}))
	assert(ecs.register_component_type(&result, "Tagged", Tagged, Tagged{}))
	return result
}

fixture :: proc(registry: ^ecs.Component_Registry, label := "authored") -> (ecs.World, ecs.Entity) {
	world := ecs.init()
	entity := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, entity, "entity", "Entity", "", ecs.Default_Layer_Mask))
	assert(ecs.add(&world, registry, entity, Plain{}))
	data := parse(`{"label":"authored","names":["first","second"],"values":[3,4],"weights":{"a":1.5},"nested":{"text":"nested"}}`)
	object := data.(json.Object)
	object["label"] = json.String(label)
	assert(ecs.add_component(&world, registry, entity, "Owned", data))
	return world, entity
}

validate_updates :: proc(tracker: ^mem.Tracking_Allocator) {
	registry := registry()
	defer ecs.destroy_registry(&registry)
	world, entity := fixture(&registry)
	defer ecs.destroy(&world)
	assert(ecs.set(&world, entity, Plain{}))
	version := ecs.change_version(&world)
	allocated := tracker.total_allocation_count
	live := tracker.current_memory_allocated
	for index in 0 ..< 10000 {
		assert(ecs.set(&world, entity, Plain{count = i32(index), position = {1,2,3}, nested = {true}}))
	}
	assert(tracker.total_allocation_count == allocated)
	assert(tracker.current_memory_allocated == live)
	assert(ecs.change_version(&world) == version + 10000)
	plain, found := ecs.get(&world, entity, Plain)
	assert(found && plain.count == 9999 && plain.nested.active)
	version = ecs.change_version(&world)
	plain.position[1] = math.inf_f32(1)
	assert(!ecs.set(&world, entity, plain))
	assert(ecs.change_version(&world) == version)
	plain, _ = ecs.get(&world, entity, Plain)
	assert(plain.position[1] == 2)

	// Caller buffers must be copied; subsequent sets borrow the previous value's
	// collections to exercise replacement before freeing aliased source storage.
	owned, _ := ecs.get(&world, entity, Owned)
	label, _ := strings.clone("caller")
	owned.label = label
	assert(ecs.set(&world, entity, owned))
	delete(label)
	owned, _ = ecs.get(&world, entity, Owned)
	assert(owned.label == "caller" && owned.nested.text == "nested")
	live = tracker.current_memory_allocated
	for index in 0 ..< 10000 {
		owned, _ = ecs.get(&world, entity, Owned)
		owned.label = "even" if index % 2 == 0 else "odd"
		assert(ecs.set(&world, entity, owned))
	}
	assert(tracker.current_memory_allocated <= live + 2048)
	assert(len(world.typed_value_arenas) == 2)
	owned, _ = ecs.get(&world, entity, Owned)
	assert(owned.label == "odd" && owned.names[1] == "second" && owned.weights["a"] == 1.5)
	assert(owned.nested.text == "nested")
	assert(len(owned.values) == 2 && owned.values[1] == 4)

	// A failed JSON conversion leaves both the component and its ownership intact.
	bad_weights := make(map[string]f32)
	bad_weights["bad"] = math.inf_f32(1)
	owned.weights = bad_weights
	version = ecs.change_version(&world)
	live = tracker.current_memory_allocated
	assert(!ecs.set(&world, entity, owned))
	assert(ecs.change_version(&world) == version)
	assert(tracker.current_memory_allocated == live)
	delete(bad_weights)
	owned, _ = ecs.get(&world, entity, Owned)
	assert(owned.weights["a"] == 1.5 && owned.label == "odd")

	// Large transient values must also be released when replaced by small ones.
	large := make([]u8, 128*1024)
	for &byte in large {byte = 'x'}
	owned.label = string(large)
	assert(ecs.set(&world, entity, owned))
	delete(large)
	owned, _ = ecs.get(&world, entity, Owned)
	assert(len(owned.label) == 128*1024)
	owned.label = "small"
	assert(ecs.set(&world, entity, owned))
	assert(tracker.current_memory_allocated < live + 2048)

	assert(ecs.add(&world, &registry, entity, Tagged{}))
	assert(ecs.set(&world, entity, Tagged{count = 5, ignored = 9}))
	tagged, _ := ecs.get(&world, entity, Tagged)
	assert(tagged.count == 5 && tagged.ignored == 0)
	data, ok := ecs.runtime_component_json(&world, entity, "Plain")
	assert(ok && data.(json.Object)["count"].(json.Integer) == 9999)
	owned, _ = ecs.get(&world, entity, Owned)
	owned.label = "Owned"
	assert(ecs.set(&world, entity, owned))
	owned, _ = ecs.get(&world, entity, Owned)
	assert(ecs.set_typed_component(&world, entity, owned.label, owned))
	owned, _ = ecs.get(&world, entity, Owned)
	assert(ecs.remove_component(&world, entity, owned.label))
	assert(len(world.typed_value_arenas) == 2)
	assert(!ecs.set(&world, entity, Owned{}))
	assert(ecs.add(&world, &registry, entity, Owned{label = "re-added"}))
	owned, _ = ecs.get(&world, entity, Owned)
	assert(owned.label == "re-added")
	assert(ecs.destroy_entity(&world, entity))
	assert(len(world.typed_value_arenas) == 0)
}

validate_reload :: proc(tracker: ^mem.Tracking_Allocator) {
	registry := registry()
	defer ecs.destroy_registry(&registry)
	world, entity := fixture(&registry)
	defer ecs.destroy(&world)
	assert(ecs.set(&world, entity, Plain{count = 42}))
	live: i64
	for index in 0 ..< 64 {
		label := "even" if index % 2 == 0 else "odd"
		snapshot, _ := fixture(&registry, label)
		version := ecs.change_version(&world)
		assert(ecs.apply_value_snapshot(&world, &snapshot))
		ecs.destroy(&snapshot)
		assert(ecs.change_version(&world) == version + 1)
		plain, _ := ecs.get(&world, entity, Plain)
		assert(plain.count == 42) // Unchanged authored data preserves runtime values.
		owned, _ := ecs.get(&world, entity, Owned)
		assert(owned.label == label && owned.names[0] == "first")
		assert(ecs.set(&world, entity, owned))
		if index == 2 {live = tracker.current_memory_allocated}
		if index > 2 {assert(tracker.current_memory_allocated <= live + 2048)}
	}
}
