package ecs

import "core:math"
import b2 "vendor:box2d"

// Native bodies have fixed rotation, so linear velocity is also the velocity
// at the contact point. Transform edits are teleports, not platform motion.
character_support_velocity_2d :: proc(world: ^World, entity: Entity) -> [2]f32 {
	native,found := world.box2d_bodies[entity]
	if !found || !is_enabled(world,entity) || !b2.Body_IsValid(native) {return {}}
	if b2.Body_GetType(native) == .staticBody {return {}}
	v := b2.Body_GetLinearVelocity(native)
	result := [2]f32{v.x,v.y}
	// Game systems can request more than the native world speed ceiling. Use
	// the velocity the backend will actually integrate when predicting carry.
	speed := math.sqrt(result[0]*result[0]+result[1]*result[1])
	limit := b2.World_GetMaximumLinearSpeed(world.box2d_world)
	if speed > limit {result *= limit/speed}
	return result
}

// Invalidate dependants before destroying/moving native geometry. This clears
// coyote support too, so a rebuilt body cannot grant a jump from stale contact.
// Already launched momentum belongs to the character and survives source removal.
character_controllers_2d_forget_support :: proc(world: ^World, support: Entity) {
	one_way_forget_2d(world,support)
	for entity, &state in world.character_controller_states_2d {
		if state.wall_entity == support {
			state.wall_entity,state.wall_component,state.wall_normal,state.wall_velocity = 0,"",{},{}
			state.wall_sliding = false
			state.ignore_contacts = true
		}
		if state.drop_entity == support {state.drop_entity,state.drop_component,state.drop_remaining = 0,"",0; state.drop_requested = false}
		if state.support_entity != support {continue}
		state.support_component = ""
		state.support_entity,state.support_velocity = 0,{}
		state.grounded,state.ground_normal = false,{}
		state.coyote_remaining = 0
		state.ignore_contacts = true
		if body,found := world.rigid_bodies_2d[entity]; found && body.grounded {
			body.grounded = false
			world.rigid_bodies_2d[entity] = body
			record_component_change(world,entity,"RigidBody2D",.Changed)
		}
	}
}

// Preserve the velocity reference already included in RigidBody2D.velocity.
// Clearing it while keeping that velocity would add platform motion twice when
// support is reacquired. Inputs, support handles and grace timers still reset.
character_controller_2d_reset_state :: proc(world: ^World, entity: Entity, preserve_posture := false) {
	if previous,found := world.character_controller_states_2d[entity]; found {
		next := Character_Controller_State_2D{inherited_velocity=previous.inherited_velocity}
		if preserve_posture {
			next.crouched,next.capsule_height = previous.crouched,previous.capsule_height
		} else if previous.crouched {
			if capsule,found := world.capsule_colliders_2d[entity]; found {character_capsule_native_2d(world,entity,capsule)}
		}
		world.character_controller_states_2d[entity] = next
	}
}
