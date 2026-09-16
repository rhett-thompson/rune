package main

import "core:mem"
import "rune:ecs"

runtime_reload_fixture :: proc(registry: ^ecs.Component_Registry) -> (ecs.World, ecs.Entity) {
	world := ecs.init()
	entity := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, entity, "actor", "Actor", "", 1))
	assert(ecs.add(&world, registry, entity, ecs.default_transform()))
	return world, entity
}

validate_collision_layer_reload :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, entity := runtime_reload_fixture(&registry)
	defer ecs.destroy(&world)
	assert(ecs.add(&world, &registry, entity, ecs.BoxCollider2D{size = {2, 2}}))
	assert(ecs.add(&world, &registry, entity, ecs.BoxCollider{size = {2, 2, 2}, is_static = true}))
	_, initial_2d := ecs.physics_2d_raycast(&world, {-3, 0}, {6, 0}, {layers = 1})
	_, initial_3d := ecs.physics_3d_raycast(&world, {-3, 0, 0}, {6, 0, 0}, {layers = 1})
	assert(initial_2d && initial_3d)

	// Repeated changes must invalidate existing native bodies in both backends.
	for layer in ([]u64{2, 4, 1}) {
		old_layer, _ := ecs.entity_layer_mask(&world, entity)
		snapshot, other := runtime_reload_fixture(&registry)
		assert(ecs.add(&snapshot, &registry, other, ecs.BoxCollider2D{size = {2, 2}}))
		assert(ecs.add(&snapshot, &registry, other, ecs.BoxCollider{size = {2, 2, 2}, is_static = true}))
		assert(ecs.set_entity_layer_mask(&snapshot, other, layer))
		assert(ecs.apply_value_snapshot(&world, &snapshot))
		ecs.destroy(&snapshot)

		mask, found := ecs.entity_layer_mask(&world, entity)
		assert(found && mask == layer && ecs.is_alive(&world, entity))
		_, old_2d := ecs.physics_2d_raycast(&world, {-3, 0}, {6, 0}, {layers = old_layer})
		_, old_3d := ecs.physics_3d_raycast(&world, {-3, 0, 0}, {6, 0, 0}, {layers = old_layer})
		assert(!old_2d && !old_3d, "reloaded colliders must leave their old layer")
		hit_2d, new_2d := ecs.physics_2d_raycast(&world, {-3, 0}, {6, 0}, {layers = layer})
		hit_3d, new_3d := ecs.physics_3d_raycast(&world, {-3, 0, 0}, {6, 0, 0}, {layers = layer})
		assert(new_2d && new_3d && hit_2d.entity == entity && hit_3d.entity == entity)
	}
}

validate_queued_animation_reload :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_queued_animation_storage(&tracker)
	assert(len(tracker.bad_free_array) == 0 && tracker.current_memory_allocated == 0)
}

validate_queued_animation_storage :: proc(tracker: ^mem.Tracking_Allocator) {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, entity := runtime_reload_fixture(&registry)
	defer ecs.destroy(&world)
	animator := ecs.SpriteAnimator{animation = "actor.animation.json", clip = "idle", speed = 1, autoplay = true}
	assert(ecs.add(&world, &registry, entity, animator))
	assert(ecs.play_sprite_animation(&world, entity, "idle"))
	assert(ecs.queue_sprite_animation(&world, entity, "queued_attack"))
	state, _ := ecs.get_sprite_animation_state(&world, entity)
	state.frame = 2
	state.elapsed = 0.125
	assert(ecs.set_sprite_animation_state(&world, entity, state))

	for _ in 0 ..< 8 {
		snapshot, other := runtime_reload_fixture(&registry)
		assert(ecs.add(&snapshot, &registry, other, animator))
		assert(ecs.apply_value_snapshot(&world, &snapshot))
		ecs.destroy(&snapshot)
		after, found := ecs.get_sprite_animation_state(&world, entity)
		assert(found)
		// Check allocation ownership before reading the string: freed arena
		// bytes can still look correct until the heap reuses them.
		pointer := uintptr(raw_data(after.next_clip))
		allocated := false
		for _, allocation in tracker.allocation_map {
			start := uintptr(allocation.memory)
			if pointer >= start && pointer + uintptr(len(after.next_clip)) <= start + uintptr(allocation.size) {
				allocated = true
				break
			}
		}
		assert(allocated, "queued animation must remain in live storage after reload")
		assert(after.next_clip == "queued_attack")
		assert(after.frame == state.frame && after.elapsed == state.elapsed && after.playing)
	}
	assert(ecs.queue_sprite_animation(&world, entity, ""))
	snapshot, other := runtime_reload_fixture(&registry)
	assert(ecs.add(&snapshot, &registry, other, animator))
	assert(ecs.apply_value_snapshot(&world, &snapshot))
	ecs.destroy(&snapshot)
	cleared, _ := ecs.get_sprite_animation_state(&world, entity)
	assert(cleared.next_clip == "", "reload must preserve a cancelled transition")
}
