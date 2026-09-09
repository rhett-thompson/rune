package ecs

import "core:math"
import b2 "vendor:box2d"

// A short ray at the effective capsule's center checks the actual wall face.
// Rounded cap/corner contacts alone cannot grant wall movement. Requiring input
// toward the face makes idle brushing and input away ordinary airborne motion.
character_wall_refresh_2d :: proc(world: ^World, entity: Entity, config: CharacterController2D, state: ^Character_Controller_State_2D) {
	state.wall_entity,state.wall_component,state.wall_normal,state.wall_velocity = 0,"",{},{}
	if state.grounded || state.ignore_contacts || state.wall_jump_lock_remaining > 0 || state.move_x == 0 ||
		(config.wall_slide_speed == 0 && (config.wall_jump_speed_x == 0 || config.wall_jump_speed_y == 0)) {return}
	capsule,_ := get_effective_capsule_collider_2d(world,entity)
	a,b,radius := capsule_collider_2d_geometry(capsule,world.transforms[entity])
	center := (a+b)*0.5
	direction: f32 = 1 if state.move_x > 0 else -1
	query := Character_Step_Query_2D{caller_context=context,world=world,entity=entity}
	layers,_ := entity_layer_mask(world,entity)
	_ = b2.World_CastRay(world.box2d_world,{center[0],center[1]},{direction*(radius+0.05),0},
		{categoryBits=layers,maskBits=layers},character_step_cast_result_2d,&query)
	if !query.found || !is_enabled(world,query.hit.entity) || math.abs(query.hit.normal[1]) > 0.01 ||
		query.hit.normal[0]*direction >= 0 {return}
	state.wall_entity,state.wall_component = query.hit.entity,query.hit.component
	state.wall_normal = { -direction,0 }
	state.wall_velocity = character_support_velocity_2d(world,query.hit.entity)
}
