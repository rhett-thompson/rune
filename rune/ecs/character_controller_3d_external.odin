package ecs

// Add world-space velocity for the next fixed physics step only. Multiple
// sources accumulate; the motor projects onto its gravity plane, follows
// walkable ground, and sweeps the contribution alongside walking or a dash.
// Submit from fixed_update immediately before physics, omitting suspended
// sources. This does not change ordinary intent, momentum, or vertical motion.
character_controller_3d_add_external_velocity :: proc(world:^World,entity:Entity,velocity:[3]f32)->bool {
	if !character_controller_3d_ready(world,entity) || !physics_query_vector_valid(velocity) {return false}
	state:=world.character_controller_states_3d[entity]
	if state.free_motion {return false}
	combined:=state.pending_external_velocity+velocity
	if !physics_query_vector_valid(combined) || !finite_nonnegative(character_length_3d(combined)) {return false}
	state.pending_external_velocity=combined
	world.character_controller_states_3d[entity]=state
	return true
}
