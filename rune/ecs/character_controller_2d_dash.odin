package ecs

import "core:math"

// Supply a press edge and a nonzero horizontal direction. Multiple requests
// before a fixed step coalesce; the latest direction wins. Input bindings and
// remembered facing belong to game code.
character_controller_2d_dash :: proc(world: ^World, entity: Entity, direction: f32) -> bool {
	config,found := get_character_controller_2d(world,entity)
	if !found || !is_enabled(world,entity) || config.dash_speed <= 0 ||
		direction == 0 || math.is_nan(direction) || math.is_inf(direction) {return false}
	state := world.character_controller_states_2d[entity]
	state.dash_requested = true
	state.dash_request_direction = 1 if direction > 0 else -1
	world.character_controller_states_2d[entity] = state
	return true
}

character_dash_close_chain_2d :: proc(state: ^Character_Controller_State_2D, config: CharacterController2D) {
	if state.dash_chain_index > 0 {state.dash_cooldown_remaining = config.dash_cooldown}
	state.dash_chain_index,state.dash_chain_remaining = 0,0
	state.dash_queued = false
}

character_dash_cancel_2d :: proc(state: ^Character_Controller_State_2D, config: CharacterController2D) {
	state.dash_requested = false
	if state.dash_chain_index > 0 {state.dash_ended = true}
	state.dashing,state.dash_remaining = false,0
	character_dash_close_chain_2d(state,config)
}

character_dash_finish_2d :: proc(state: ^Character_Controller_State_2D, config: CharacterController2D) {
	state.dashing,state.dash_remaining,state.dash_ended = false,0,true
	if state.dash_chain_index < config.dash_chain_count && (config.dash_chain_window > 0 || state.dash_queued) {
		state.dash_chain_remaining = config.dash_chain_window
	} else {
		character_dash_close_chain_2d(state,config)
	}
}

character_dash_before_step_2d :: proc(state: ^Character_Controller_State_2D, config: CharacterController2D, velocity: ^[2]f32) {
	if state.dash_requested {
		state.dash_requested = false
		if state.dash_cooldown_remaining <= 0 && state.dash_chain_index < config.dash_chain_count {
			state.dash_queued,state.dash_queued_direction = true,state.dash_request_direction
		}
	}
	if state.dashing || !state.dash_queued {return}
	state.dash_queued = false
	allowed := config.dash_on_ground if state.grounded else config.dash_in_air
	if !allowed || config.dash_speed <= 0 {
		character_dash_close_chain_2d(state,config)
		return
	}
	state.dashing,state.dash_started = true,true
	state.dash_direction = state.dash_queued_direction
	state.dash_remaining = config.dash_duration
	state.dash_chain_remaining = 0
	state.dash_chain_index += 1
	state.wall_jump_lock_remaining,state.wall_sliding = 0,false
	state.jump_cut_available,state.jump_release_requested,state.jump_buffer_released = false,false,false
	state.jump_buffer_remaining,state.coyote_remaining = 0,0
	state.jumping = false
	if state.grounded {state.inherited_velocity = state.support_velocity}
	// Zero gravity gives a level air dash relative to inherited platform motion.
	// Nonzero scales preserve vertical momentum and scale subsequent gravity.
	if !state.grounded && config.dash_gravity_scale == 0 {
		velocity[1] = min(state.inherited_velocity[1],config.max_fall_speed)
	}
}

character_dash_after_step_2d :: proc(state: ^Character_Controller_State_2D, config: CharacterController2D, contacts: Character_Contacts_2D, dt: f32) {
	if state.dashing {
		state.dash_remaining = max(0,state.dash_remaining-dt)
		// Carry can reverse the world-space direction of an opposing dash.
		blocked := (state.velocity_x_before_step < 0 && contacts.block_left) ||
			(state.velocity_x_before_step > 0 && contacts.block_right)
		if blocked {state.dash_blocked = true}
		if blocked || state.dash_remaining <= 0.000001 {character_dash_finish_2d(state,config)}
	} else if !state.dash_ended {
		// Timers start after the completed dash, never during it. Each segment
		// consumes at least one full fixed step and queued segments start next step.
		state.dash_cooldown_remaining = max(0,state.dash_cooldown_remaining-dt)
		if state.dash_cooldown_remaining <= 0.000001 {state.dash_cooldown_remaining = 0}
		if state.dash_chain_index > 0 && !state.dash_queued {
			state.dash_chain_remaining = max(0,state.dash_chain_remaining-dt)
			if state.dash_chain_remaining <= 0.000001 {character_dash_close_chain_2d(state,config)}
		}
	}
}
