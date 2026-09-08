package ecs

import "base:runtime"
import b2 "vendor:box2d"

// A held request, like move(). Release retries standing each fixed step until
// clear. Posture is runtime state, never a mutation of authored capsule data.
character_controller_2d_crouch :: proc(world: ^World, entity: Entity, held: bool) -> bool {
	if !has_component_data(world,entity,"CharacterController2D") || !is_enabled(world,entity) {return false}
	state := world.character_controller_states_2d[entity]
	state.crouch_requested = held
	world.character_controller_states_2d[entity] = state
	return true
}

character_capsule_at_height_2d :: proc(capsule: CapsuleCollider2D, pose: Transform, height: f32) -> CapsuleCollider2D {
	result := capsule
	result.height = clamp(height,2*capsule.radius,capsule.height)
	// Preserve world-space bottom even with a reflected or nonuniform scale.
	sign: f32 = -1 if pose.scale[1] < 0 else 1
	result.offset[1] += sign*(capsule.height-result.height)*0.5
	return result
}

get_effective_capsule_collider_2d :: proc(world: ^World, entity: Entity) -> (CapsuleCollider2D, bool) {
	capsule,found := world.capsule_colliders_2d[entity]
	state := world.character_controller_states_2d[entity]
	if found && state.crouched {capsule = character_capsule_at_height_2d(capsule,world.transforms[entity],state.capsule_height)}
	return capsule,found
}

Character_Clearance_2D :: struct {
	caller_context: runtime.Context,
	world: ^World,
	entity: Entity,
	blocked: bool,
}

character_clearance_overlap_2d :: proc "c" (shape: b2.ShapeId, ctx: rawptr) -> bool {
	query := cast(^Character_Clearance_2D)ctx
	context = query.caller_context
	owner,found := physics_2d_entity_from_shape(query.world,shape)
	if !found || owner.entity == query.entity || b2.Shape_IsSensor(shape) ||
		one_way_enabled_2d(query.world,owner.entity,owner.component) {return true}
	query.blocked = true
	return false
}

// The top cap sweeps through exactly the additional space occupied by growth.
// A small inset allows resting contact with a wall or floor at solver slop.
character_capsule_can_grow_2d :: proc(world: ^World, entity: Entity, current, target: CapsuleCollider2D) -> bool {
	pose := world.transforms[entity]
	a,b,radius := capsule_collider_2d_geometry(current,pose)
	c,d,_ := capsule_collider_2d_geometry(target,pose)
	old_top := a if a[1] < b[1] else b
	new_top := c if c[1] < d[1] else d
	if new_top[1] >= old_top[1] {return true}
	query := Character_Clearance_2D{caller_context=context,world=world,entity=entity}
	proxy := b2.ShapeProxy{count=2,radius=max(radius-0.005,radius*0.99)}
	proxy.points[0],proxy.points[1] = {old_top[0],old_top[1]},{new_top[0],new_top[1]}
	layers,_ := entity_layer_mask(world,entity)
	_ = b2.World_OverlapShape(world.box2d_world,proxy,{categoryBits=layers,maskBits=layers},character_clearance_overlap_2d,&query)
	return !query.blocked
}

// Update the shape in place: keep the body, shape identity, velocity, support
// reference and drop guard. Applying mass can shift center-of-mass velocity;
// fixed rotation means restoring the supplied linear velocity is sufficient.
character_capsule_native_2d :: proc(world: ^World, entity: Entity, capsule: CapsuleCollider2D) {
	native,found := physics_2d_native_body(world,entity)
	if !found {return}
	pose := world.transforms[entity]
	pose.position = {}
	a,b,radius := capsule_collider_2d_geometry(capsule,pose)
	if radius <= 0 || !finite_nonnegative(radius) || !physics_query_vector_valid(a) || !physics_query_vector_valid(b) {return}
	for id,owner in world.physics_2d.shapes {
		if owner.entity != entity || owner.component != "CapsuleCollider2D" {continue}
		shape := transmute(b2.ShapeId)id
		if !b2.Shape_IsValid(shape) {continue}
		velocity := b2.Body_GetLinearVelocity(native)
		if a == b {b2.Shape_SetCircle(shape,{center={a[0],a[1]},radius=radius})}
		else {b2.Shape_SetCapsule(shape,{center1={a[0],a[1]},center2={b[0],b[1]},radius=radius})}
		b2.Body_ApplyMassFromShapes(native)
		b2.Body_SetLinearVelocity(native,velocity)
		b2.Body_SetAwake(native,true)
		return
	}
}

character_crouch_before_step_2d :: proc(world: ^World, entity: Entity, config: CharacterController2D, state: ^Character_Controller_State_2D) {
	authored := world.capsule_colliders_2d[entity]
	pose := world.transforms[entity]
	current := authored
	if state.crouched {current = character_capsule_at_height_2d(authored,pose,state.capsule_height)}
	target := authored
	if state.crouch_requested && config.crouch_height > 0 {target = character_capsule_at_height_2d(authored,pose,config.crouch_height)}
	state.stand_blocked = false
	if target.height > current.height && !character_capsule_can_grow_2d(world,entity,current,target) {
		state.stand_blocked = true
		return
	}
	state.crouched = target.height < authored.height
	state.capsule_height = target.height if state.crouched else 0
	if current.height == target.height {return}
	character_capsule_native_2d(world,entity,target)
	state.posture_changed,state.ignore_contacts = true,true
}
