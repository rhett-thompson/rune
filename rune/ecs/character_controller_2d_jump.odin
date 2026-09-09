package ecs

// Send an input release edge, not a held-up state. It waits for fixed update;
// a pending buffered press remembers the release until it launches or expires.
character_controller_2d_release_jump :: proc(world: ^World, entity: Entity) -> bool {
	if !has_component_data(world,entity,"CharacterController2D") || !is_enabled(world,entity) {return false}
	state := world.character_controller_states_2d[entity]
	state.jump_release_requested = true
	if state.jump_requested || state.jump_buffer_remaining > 0 {state.jump_buffer_released = true}
	world.character_controller_states_2d[entity] = state
	return true
}

character_jump_release_2d :: proc(state: ^Character_Controller_State_2D, config: CharacterController2D, velocity: ^[2]f32) {
	if !state.jump_release_requested {return}
	state.jump_release_requested = false
	if !state.jump_cut_available {return}
	state.jump_cut_available = false // At most one cut per launched jump.
	if !state.jumping || state.grounded {return}
	upward := velocity[1]-state.jump_launch_velocity_y
	if upward >= 0 || config.jump_cut_multiplier == 1 {return}
	// A descending platform can turn a cut into positive world velocity.
	// Keep the controller's configured terminal speed in force.
	velocity[1] = min(state.jump_launch_velocity_y+upward*config.jump_cut_multiplier,config.max_fall_speed)
	state.jump_cut_applied = true
}
