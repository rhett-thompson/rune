package ecs

import "core:encoding/json"
import "core:math"

// Clips come from the ModelRenderer model's embedded animation library.
// Empty clip selects the first clip. R3D resources stay in r3d_bridge.
ModelAnimator :: struct {
	clip:     string,
	speed:    f32,
	loop:     bool,
	autoplay: bool,
}

Model_Animation_State :: struct {
	elapsed:     f32,
	duration:    f32,
	playing:     bool,
	finished:    bool,
	initialized: bool,
}

model_animator_from_json :: proc(data: json.Value) -> (ModelAnimator, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := ModelAnimator {
		speed    = 1,
		loop     = true,
		autoplay = true,
	}
	if value, found := object["clip"]; found {
		result.clip, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["speed"]; found {
		result.speed, ok = read_number(value)
		if !ok {return {}, false}
	}
	if value, found := object["loop"]; found {
		result.loop, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	if value, found := object["autoplay"]; found {
		result.autoplay, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	return result, component_value_valid(result)
}

get_model_animator :: proc(world: ^World, entity: Entity) -> (ModelAnimator, bool) {
	value, found := world.model_animators[entity]
	return value, found
}

set_model_animator :: proc(world: ^World, entity: Entity, value: ModelAnimator) -> bool {
	if !has_component_data(world, entity, "ModelAnimator") ||
	   !component_value_valid(value) {return false}
	owned := value
	owned.clip = retain_scene_string(world, value.clip)
	commit_component_value(world, entity, "ModelAnimator", &world.model_animators, owned)
	return true
}

play_model_animation :: proc(
	world: ^World,
	entity: Entity,
	clip: string,
	restart := true,
) -> bool {
	animator, found := get_model_animator(world, entity)
	if !found {return false}
	changed := animator.clip != clip
	animator.clip = clip
	if !set_model_animator(world, entity, animator) {return false}
	state := world.model_animation_states[entity]
	if restart || changed {
		// Negative sentinel is resolved once the imported duration is known.
		state.elapsed = -1 if animator.speed < 0 else 0
	}
	state.initialized = true
	state.playing = true
	state.finished = false
	world.model_animation_states[entity] = state
	return true
}

pause_model_animation :: proc(world: ^World, entity: Entity) -> bool {
	if !has_component_data(world, entity, "ModelAnimator") {return false}
	state := world.model_animation_states[entity]
	state.initialized = true
	state.playing = false
	world.model_animation_states[entity] = state
	return true
}

resume_model_animation :: proc(world: ^World, entity: Entity) -> bool {
	if !has_component_data(world, entity, "ModelAnimator") {return false}
	state := world.model_animation_states[entity]
	state.initialized = true
	state.playing = true
	state.finished = false
	world.model_animation_states[entity] = state
	return true
}

stop_model_animation :: proc(world: ^World, entity: Entity) -> bool {
	if !pause_model_animation(world, entity) {return false}
	state := world.model_animation_states[entity]
	state.elapsed = 0
	state.finished = false
	world.model_animation_states[entity] = state
	return true
}

get_model_animation_state :: proc(world: ^World, entity: Entity) -> (Model_Animation_State, bool) {
	value, found := world.model_animation_states[entity]
	return value, found
}

// Seconds, independent of the imported clip's tick rate.
seek_model_animation :: proc(world: ^World, entity: Entity, seconds: f32) -> bool {
	if !has_component_data(world, entity, "ModelAnimator") ||
	   seconds < 0 ||
	   math.is_nan(seconds) ||
	   math.is_inf(seconds) {return false}
	state := world.model_animation_states[entity]
	if !state.initialized {state.playing = world.model_animators[entity].autoplay}
	state.initialized = true
	state.elapsed = seconds
	state.finished = false
	world.model_animation_states[entity] = state
	return true
}
