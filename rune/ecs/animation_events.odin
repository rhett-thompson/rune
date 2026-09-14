package ecs

import "core:strings"

// Events describe frame entries, including frames skipped by a long update.
Sprite_Animation_Event :: struct {
	entity: Entity,
	animation: string,
	clip: string,
	name: string,
	frame: int,
}

MAX_SPRITE_ANIMATION_EVENTS :: 4096

// Borrowed read-only until the next animation update, explicit clear, or World
// destruction. Reading is nondestructive so multiple systems can observe events.
sprite_animation_events :: proc(world: ^World) -> []Sprite_Animation_Event {
	if world == nil {return nil}
	return world.sprite_animation_event_buffer[:]
}

sprite_animation_events_overflowed :: proc(world: ^World) -> bool {
	return world != nil && world.sprite_animation_event_overflow
}

clear_sprite_animation_events :: proc(world: ^World) {
	if world == nil {return}
	allocator := world.sprite_animation_event_buffer.allocator
	for event in world.sprite_animation_event_buffer {
		delete(event.animation, allocator)
		delete(event.clip, allocator)
		delete(event.name, allocator)
	}
	clear(&world.sprite_animation_event_buffer)
	world.sprite_animation_event_overflow = false
}

// Used by the animation update. Own text independently of reloaded assets and
// removed components. A bounded buffer also bounds work at extreme clip speeds.
append_sprite_animation_event :: proc(world: ^World, event: Sprite_Animation_Event) -> bool {
	if world == nil {return false}
	if len(world.sprite_animation_event_buffer) >= MAX_SPRITE_ANIMATION_EVENTS {
		world.sprite_animation_event_overflow = true
		return false
	}
	if world.sprite_animation_event_buffer.allocator.procedure == nil {
		world.sprite_animation_event_buffer = make([dynamic]Sprite_Animation_Event)
	}
	allocator := world.sprite_animation_event_buffer.allocator
	owned := event
	owned.animation, _ = strings.clone(event.animation, allocator)
	owned.clip, _ = strings.clone(event.clip, allocator)
	owned.name, _ = strings.clone(event.name, allocator)
	append(&world.sprite_animation_event_buffer, owned)
	return true
}
