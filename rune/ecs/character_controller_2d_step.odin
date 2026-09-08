package ecs

import "base:runtime"
import "core:math"
import b2 "vendor:box2d"

Character_Step_Query_2D :: struct {
	caller_context: runtime.Context,
	world: ^World,
	entity: Entity,
	descending: bool,
	hit: Raycast_Hit_2D,
	found: bool,
}

character_step_cast_result_2d :: proc "c" (shape: b2.ShapeId, point, normal: b2.Vec2, fraction: f32, ctx: rawptr) -> f32 {
	query := cast(^Character_Step_Query_2D)ctx
	context = query.caller_context
	owner,found := physics_2d_entity_from_shape(query.world,shape)
	if !found || owner.entity == query.entity || b2.Shape_IsSensor(shape) {return -1}
	if one_way_enabled_2d(query.world,owner.entity,owner.component) {
		// Upward/sideways passage stays free. A raised trial pose must not
		// manufacture eligibility to land on a one-way top from underneath.
		if !query.descending || !one_way_cast_2d(query.world,query.entity,shape,normal) {return -1}
	}
	if !query.found || fraction < query.hit.fraction {
		query.hit = {owner.entity,owner.component,{point.x,point.y},{normal.x,normal.y},fraction}
		query.found = true
	}
	return query.hit.fraction
}

character_step_cast_2d :: proc(world: ^World, entity: Entity, proxy: b2.ShapeProxy, translation: [2]f32, descending := false) -> (Raycast_Hit_2D,bool) {
	query := Character_Step_Query_2D{caller_context=context,world=world,entity=entity,descending=descending}
	layers,_ := entity_layer_mask(world,entity)
	_ = b2.World_CastShape(world.box2d_world,proxy,{translation[0],translation[1]},
		{categoryBits=layers,maskBits=layers},character_step_cast_result_2d,&query)
	return query.hit,query.found
}

character_step_surface_2d :: proc(world: ^World, entity: Entity, origin, translation: [2]f32) -> (Raycast_Hit_2D,bool) {
	query := Character_Step_Query_2D{caller_context=context,world=world,entity=entity,descending=true}
	layers,_ := entity_layer_mask(world,entity)
	_ = b2.World_CastRay(world.box2d_world,{origin[0],origin[1]},{translation[0],translation[1]},
		{categoryBits=layers,maskBits=layers},character_step_cast_result_2d,&query)
	return query.hit,query.found
}

character_step_proxy_offset_2d :: proc(proxy: b2.ShapeProxy, offset: [2]f32) -> b2.ShapeProxy {
	result := proxy
	for i in 0..<int(result.count) {result.points[i] += {offset[0],offset[1]}}
	return result
}

// Only lift the body here. The native step consumes its ordinary horizontal
// velocity once; probing ahead must never add extra horizontal travel.
character_step_up_2d :: proc(world: ^World, entity: Entity, config: CharacterController2D, state: ^Character_Controller_State_2D,
	velocity_x,dt: f32, contacts: Character_Contacts_2D) -> bool {
	if config.step_height <= 0 || !state.grounded || state.jumping ||
		state.move_x == 0 || velocity_x*state.move_x <= 0 {return false}
	limit := b2.World_GetMaximumLinearSpeed(world.box2d_world)
	dx := clamp(velocity_x,-limit,limit)*dt
	if math.abs(dx) < 0.0001 {return false}
	direction: f32 = 1 if dx > 0 else -1
	capsule,_ := get_effective_capsule_collider_2d(world,entity)
	pose := world.transforms[entity]
	a,b,radius := capsule_collider_2d_geometry(capsule,pose)
	slop := min(f32(0.005),radius*0.01)
	proxy := b2.ShapeProxy{count=2,radius=radius-slop}
	proxy.points[0],proxy.points[1] = {a[0],a[1]},{b[0],b[1]}
	min_up := math.cos(config.max_slope_angle*math.PI/180)
	front,blocked := character_step_cast_2d(world,entity,proxy,{dx,0})
	wall_contact := contacts.block_right if dx > 0 else contacts.block_left
	if !wall_contact && (!blocked || -front.normal[1] >= min_up) {return false}
	// Restrict the lift to available headroom, allowing a small curb even
	// when the full configured maximum would touch the ceiling.
	lift := config.step_height
	ceiling,above := character_step_cast_2d(world,entity,proxy,{0,-lift})
	if above {lift = max(0,lift*ceiling.fraction-slop)}
	if lift <= slop {return false}
	raised := character_step_proxy_offset_2d(proxy,{0,-lift})
	_,forward_blocked := character_step_cast_2d(world,entity,raised,{dx,0})
	if forward_blocked {return false}
	ahead := character_step_proxy_offset_2d(raised,{dx,0})
	landing,found := character_step_cast_2d(world,entity,ahead,{0,lift+slop},true)
	if !found {return false}
	rise := lift-(lift+slop)*landing.fraction+slop
	if rise <= slop || rise > config.step_height+slop {return false}
	// Capsule normals near a convex stair edge include its rounded cap.
	// Sample the actual face just inside that edge for the slope limit.
	surface,has_surface := character_step_surface_2d(world,entity,
		{landing.point[0]+direction*0.02,landing.point[1]-config.step_height-slop},{0,config.step_height+2*slop})
	if !has_surface || surface.entity != landing.entity || surface.component != landing.component || -surface.normal[1] < min_up {return false}
	feet := max(a[1],b[1])+radius
	if feet-surface.point[1] > config.step_height+slop {return false}
	// Check the lower lift too: a ceiling at the destination can be missed
	// by a path raised higher than the eventual landing pose.
	_,path_blocked := character_step_cast_2d(world,entity,character_step_proxy_offset_2d(proxy,{0,-rise}),{dx,0})
	if path_blocked {return false}
	pose.position[1] -= rise
	world.transforms[entity] = pose
	record_component_change(world,entity,"Transform",.Changed)
	native := world.box2d_bodies[entity]
	b2.Body_SetTransform(native,{pose.position[0],pose.position[1]},b2.Body_GetRotation(native))
	state.stepped = true
	state.step_support,state.step_component,state.step_normal = surface.entity,surface.component,surface.normal
	state.ground_normal = surface.normal
	state.support_entity,state.support_component = surface.entity,surface.component
	state.support_velocity = character_support_velocity_2d(world,surface.entity)
	return true
}

// Confirm the predicted support after native motion. A rounded stair edge may
// briefly have a steep capsule contact even though its actual top is flat.
character_step_contact_2d :: proc(world: ^World, entity: Entity, state: ^Character_Controller_State_2D, contacts: ^Character_Contacts_2D) {
	if !state.stepped || contacts.grounded {return}
	hit,found := character_ground_cast_2d(world,entity,0.05)
	if !found || hit.entity != state.step_support || hit.component != state.step_component {return}
	contacts.grounded,contacts.normal = true,state.step_normal
	contacts.support_entity,contacts.support_component = hit.entity,hit.component
	contacts.support_velocity = character_support_velocity_2d(world,hit.entity)
}
