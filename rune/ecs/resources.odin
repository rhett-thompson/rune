package ecs

import "core:mem"

// Resources hold typed system-wide state that does not belong to one entity.
// Their pointers remain stable for the lifetime of the World.
add_resource :: proc(world: ^World, value: $T) -> bool {
	if world == nil || world.typed_component_arena == nil {return false}
	id := typeid_of(T)
	if _, exists := world.resources[id]; exists {return false}
	storage, allocation_error := mem.new(
		T,
		mem.dynamic_arena_allocator(world.typed_component_arena),
	)
	if allocation_error != nil {return false}
	storage^ = value
	world.resources[id] = any {
		data = storage,
		id   = id,
	}
	return true
}

resource :: proc(world: ^World, $T: typeid) -> (^T, bool) {
	value, found := world.resources[typeid_of(T)]
	if !found || value.id != typeid_of(T) {return nil, false}
	return (^T)(value.data), true
}

remove_resource :: proc(world: ^World, $T: typeid) -> bool {
	id := typeid_of(T)
	if _, found := world.resources[id]; !found {return false}
	delete_key(&world.resources, id)
	return true
}
