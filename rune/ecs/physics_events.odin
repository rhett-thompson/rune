package ecs

// Events are per shape pair. A 3D entity with two colliders can produce two
// pairs. Sensor events put the sensor first; contact order comes from the backend.
Physics_Shape :: struct {
	entity:    Entity,
	component: string,
}

Physics_Event_Kind :: enum {
	Begin,
	End,
}

Physics_Event :: struct {
	kind:      Physics_Event_Kind,
	a, b:      Physics_Shape,
	is_sensor: bool,
}

Physics_Pair :: struct {
	a, b:      u64,
	is_sensor: bool,
}

Physics_State :: struct {
	needs_sync: bool,
	shapes:  map[u64]Physics_Shape,
	pairs:   map[Physics_Pair]Physics_Event,
	events:  [dynamic]Physics_Event,
	pending: [dynamic]Physics_Event,
}

physics_state_init :: proc() -> Physics_State {
	return {
		needs_sync = true,
		shapes = make(map[u64]Physics_Shape),
		pairs = make(map[Physics_Pair]Physics_Event),
		events = make([dynamic]Physics_Event),
		pending = make([dynamic]Physics_Event),
	}
}

physics_state_destroy :: proc(state: ^Physics_State) {
	delete(state.shapes)
	delete(state.pairs)
	delete(state.events)
	delete(state.pending)
	state^ = {}
}

physics_state_reset :: proc(state: ^Physics_State) {
	state.needs_sync = true
	clear(&state.shapes)
	clear(&state.pairs)
	clear(&state.events)
	clear(&state.pending)
}

physics_begin_update :: proc(state: ^Physics_State) {
	clear(&state.events)
	append(&state.events, ..state.pending[:])
	clear(&state.pending)
}

physics_pair_event :: proc(
	state: ^Physics_State,
	a, b: u64,
	sensor: bool,
	kind: Physics_Event_Kind,
) {
	key := Physics_Pair{a, b, sensor}
	if !sensor && a > b {key.a, key.b = b, a}
	if kind == .End {
		if event, found := state.pairs[key]; found {
			event.kind = .End
			append(&state.events, event)
			delete_key(&state.pairs, key)
		}
		return
	}
	if _, exists := state.pairs[key]; exists {return}
	first, first_ok := state.shapes[a]
	second, second_ok := state.shapes[b]
	if !first_ok || !second_ok {return}
	event := Physics_Event{.Begin, first, second, sensor}
	state.pairs[key] = event
	append(&state.events, event)
}

// Keep the published buffer stable if gameplay destroys a body while iterating.
// Retiring pairs here also avoids dereferencing invalid native IDs in end events.
physics_forget_entity :: proc(state: ^Physics_State, entity: Entity) {
	for key, &event in state.pairs {
		if event.a.entity != entity && event.b.entity != entity {continue}
		event.kind = .End
		append(&state.pending, event)
		delete_key(&state.pairs, key)
	}
	for key, shape in state.shapes {
		if shape.entity == entity {delete_key(&state.shapes, key)}
	}
}

// Borrowed until the next physics update or shutdown for this dimension.
// Read in System.post_physics to observe every fixed step. Removed entities
// retain their old handles in End events; check is_alive before accessing.
physics_2d_events :: proc(world: ^World) -> []Physics_Event {return world.physics_2d.events[:]}
physics_3d_events :: proc(world: ^World) -> []Physics_Event {return world.physics_3d.events[:]}
