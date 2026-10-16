package ecs

import "core:math"

// Begin a finite world-space tangent burst using the ordinary capsule motor.
// Direction is projected onto the current gravity frame and frozen at trigger.
// Gravity, jumping, moving supports, slopes, and collision remain enabled.
// Games own input policy, grounded restrictions, cooldowns, and burst tuning.
character_controller_3d_dash :: proc(world:^World,entity:Entity,direction:[3]f32,speed,duration:f32)->bool {
	if !character_controller_3d_ready(world,entity) || !physics_query_vector_valid(direction) ||
		!finite_nonnegative(speed) || !finite_nonnegative(duration) || speed<=0 || duration<=0 {return false}
	state:=world.character_controller_states_3d[entity]
	if state.free_motion || state.dashing {return false}
	up:=state.up
	if character_length_3d(up)<0.0001 {up={0,1,0}}
	heading:=direction-up*character_dot_3d(direction,up)
	length:=character_length_3d(heading)
	if length<0.0001 || math.is_inf(length) || math.is_nan(length) {return false}
	state.dashing=true
	state.dash_direction=heading/length
	state.dash_speed,state.dash_remaining=speed,duration
	state.dash_resume_velocity=state.velocity
	world.character_controller_states_3d[entity]=state
	return true
}

// Cancel a burst and its tangent momentum immediately. Vertical motion remains
// intact; send zero ordinary movement too when a menu captures player input.
character_controller_3d_cancel_dash :: proc(world:^World,entity:Entity)->bool {
	if !has_component_data(world,entity,"CharacterController3D") {return false}
	state:=world.character_controller_states_3d[entity]
	if !state.dashing {return true}
	up:=state.up
	if character_length_3d(up)<0.0001 {up={0,1,0}}
	state.velocity=up*character_dot_3d(state.dash_resume_velocity,up)
	character_dash_clear_3d(&state)
	world.character_controller_states_3d[entity]=state
	return true
}

@(private)
character_dash_clear_3d :: proc(state:^Character_Controller_State_3D) {
	state.dashing=false
	state.dash_direction,state.dash_resume_velocity={},{}
	state.dash_speed,state.dash_remaining=0,0
}

@(private)
character_dash_velocity_3d :: proc(state:^Character_Controller_State_3D,ordinary,up:[3]f32)->[3]f32 {
	heading:=state.dash_direction-up*character_dot_3d(state.dash_direction,up)
	length:=character_length_3d(heading)
	if length<0.0001 {return ordinary}
	velocity:=heading*(state.dash_speed/length)
	if state.grounded {return character_ground_velocity_3d(velocity,state.ground_normal,up,state.dash_speed)}
	// Platform carry is already applied separately while grounded. In the air,
	// match ordinary movement's inherited tangent velocity without changing fall.
	return velocity+state.inherited_velocity-up*character_dot_3d(state.inherited_velocity,up)+
		up*character_dot_3d(ordinary,up)
}
