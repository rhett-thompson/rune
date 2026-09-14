package ecs

import "core:strings"

Model_Animation_Event :: struct {
	entity: Entity,
	model, clip, name: string,
	time: f32,
	reverse: bool,
}

MAX_MODEL_ANIMATION_EVENTS :: 4096

// Borrowed read-only until the next bridge animation update, clear, or World
// destruction. Separate from sprite events so either updater can run first.
model_animation_events :: proc(world: ^World) -> []Model_Animation_Event {
	if world == nil {return nil}
	return world.model_animation_event_buffer[:]
}

model_animation_events_overflowed :: proc(world: ^World) -> bool {
	return world != nil && world.model_animation_event_overflow
}

clear_model_animation_events :: proc(world: ^World) {
	if world == nil {return}
	allocator := world.model_animation_event_buffer.allocator
	for event in world.model_animation_event_buffer {
		delete(event.model, allocator)
		delete(event.clip, allocator)
		delete(event.name, allocator)
	}
	clear(&world.model_animation_event_buffer)
	world.model_animation_event_overflow = false
}

append_model_animation_event :: proc(world: ^World, event: Model_Animation_Event) -> bool {
	if world == nil {return false}
	if len(world.model_animation_event_buffer) >= MAX_MODEL_ANIMATION_EVENTS {
		world.model_animation_event_overflow = true
		return false
	}
	if world.model_animation_event_buffer.allocator.procedure == nil {
		world.model_animation_event_buffer = make([dynamic]Model_Animation_Event)
	}
	allocator := world.model_animation_event_buffer.allocator
	owned := event
	owned.model, _ = strings.clone(event.model, allocator)
	owned.clip, _ = strings.clone(event.clip, allocator)
	owned.name, _ = strings.clone(event.name, allocator)
	append(&world.model_animation_event_buffer, owned)
	return true
}
