package ecs

import "core:encoding/json"
import "core:math"
import b2 "vendor:box2d"

// Configuration only. Input requests and simulation state live separately.
CharacterController2D :: struct {
	move_speed: f32,
	acceleration: f32,
	air_acceleration: f32,
	gravity: f32,
	jump_speed: f32,
	jump_cut_multiplier: f32,
	max_fall_speed: f32,
	max_slope_angle: f32,
	ground_snap_distance: f32,
	coyote_time: f32,
	jump_buffer_time: f32,
	drop_speed: f32,
	drop_time: f32,
	crouch_height: f32,
	crouch_speed: f32,
	step_height: f32,
	wall_slide_speed: f32,
	wall_jump_speed_x: f32,
	wall_jump_speed_y: f32,
	wall_jump_lock_time: f32,
	dash_speed: f32,
	dash_duration: f32,
	dash_cooldown: f32,
	dash_chain_count: int,
	dash_chain_window: f32,
	dash_on_ground: bool,
	dash_in_air: bool,
	dash_gravity_scale: f32,
}

Character_Controller_State_2D :: struct {
	active: bool,
	crouch_requested: bool,
	crouched: bool,
	stand_blocked: bool,
	posture_changed: bool,
	stepped: bool,
	step_normal: [2]f32,
	step_support: Entity,
	step_component: string,
	// Effective local height while crouched; authored capsule data stays intact.
	capsule_height: f32,
	grounded: bool,
	ground_normal: [2]f32,
	// Latest support is retained through coyote time, then cleared on expiry.
	support_entity: Entity,
	support_component: string,
	support_velocity: [2]f32,
	// Velocity reference applied by the motor; retained in the air after departure.
	inherited_velocity: [2]f32,
	ignore_contacts: bool,
	velocity_x_before_step: f32,
	velocity_y_before_step: f32,
	move_x: f32,
	jump_requested: bool,
	jump_release_requested: bool,
	jump_buffer_released: bool,
	jump_cut_available: bool,
	jump_cut_applied: bool,
	// Frozen takeoff reference; a platform cannot steer an airborne jump.
	jump_launch_velocity_y: f32,
	drop_requested: bool,
	drop_entity: Entity,
	drop_component: string,
	drop_remaining: f32,
	jumping: bool,
	coyote_remaining: f32,
	jump_buffer_remaining: f32,
	wall_entity: Entity,
	wall_component: string,
	wall_normal: [2]f32,
	wall_velocity: [2]f32,
	wall_sliding: bool,
	wall_jumped: bool,
	wall_jump_lock_remaining: f32,
	dash_requested: bool,
	dash_request_direction: f32,
	dash_queued: bool,
	dash_queued_direction: f32,
	dashing: bool,
	dash_direction: f32,
	dash_remaining: f32,
	dash_chain_index: int,
	dash_chain_remaining: f32,
	dash_cooldown_remaining: f32,
	dash_started: bool,
	dash_ended: bool,
	dash_blocked: bool,
}

default_character_controller_2d :: proc() -> CharacterController2D {
	return {move_speed=200, acceleration=1600, air_acceleration=800,
		gravity=1200, jump_speed=460, jump_cut_multiplier=0.5, max_fall_speed=900, max_slope_angle=45,
		ground_snap_distance=8, coyote_time=0.1, jump_buffer_time=0.1, drop_speed=60, drop_time=0.15, crouch_height=20, crouch_speed=100, wall_jump_lock_time=0.15,
		dash_duration=0.15, dash_cooldown=0.4, dash_chain_count=1, dash_chain_window=0.15, dash_on_ground=true, dash_in_air=true}
}

character_controller_2d_valid :: proc(value: CharacterController2D) -> bool {
	for v in ([25]f32{value.move_speed,value.acceleration,value.air_acceleration,
		value.gravity,value.jump_speed,value.max_fall_speed,value.max_slope_angle,
		value.ground_snap_distance,value.coyote_time,value.jump_buffer_time,value.drop_speed,value.drop_time,value.crouch_height,value.crouch_speed,value.step_height,value.jump_cut_multiplier,
		value.wall_slide_speed,value.wall_jump_speed_x,value.wall_jump_speed_y,value.wall_jump_lock_time,
		value.dash_speed,value.dash_duration,value.dash_cooldown,value.dash_chain_window,value.dash_gravity_scale}) {
		if !finite_nonnegative(v) {return false}
	}
	return value.acceleration > 0 && value.gravity > 0 && value.max_fall_speed > 0 &&
		value.max_slope_angle < 89 && value.coyote_time <= 1 && value.jump_buffer_time <= 1 && value.drop_time <= 1 && value.drop_speed > 0 && value.jump_cut_multiplier <= 1 && value.wall_jump_lock_time <= 1 &&
		value.dash_duration > 0 && value.dash_duration <= 1 && value.dash_chain_window <= 1 && value.dash_chain_count >= 1 && value.dash_chain_count <= 32
}

character_controller_2d_from_json :: proc(data: json.Value) -> (CharacterController2D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := default_character_controller_2d()
	for key, value in object {
		if key == "dash_on_ground" || key == "dash_in_air" {
			flag,valid := value.(bool)
			if !valid {return {},false}
			if key == "dash_on_ground" {result.dash_on_ground = flag} else {result.dash_in_air = flag}
			continue
		}
		if key == "dash_chain_count" {
			count: f64
			#partial switch v in value {
			case json.Integer: count = f64(v)
			case json.Float: count = v
			case: return {},false
			}
			if math.is_nan(count) || count < 1 || count > 32 || count != math.floor(count) {return {},false}
			result.dash_chain_count = int(count)
			continue
		}
		number, valid := read_number(value)
		if !valid {return {}, false}
		switch key {
		case "move_speed": result.move_speed = number
		case "acceleration": result.acceleration = number
		case "air_acceleration": result.air_acceleration = number
		case "gravity": result.gravity = number
		case "jump_speed": result.jump_speed = number
		case "jump_cut_multiplier": result.jump_cut_multiplier = number
		case "max_fall_speed": result.max_fall_speed = number
		case "max_slope_angle": result.max_slope_angle = number
		case "ground_snap_distance": result.ground_snap_distance = number
		case "coyote_time": result.coyote_time = number
		case "jump_buffer_time": result.jump_buffer_time = number
		case "drop_speed": result.drop_speed = number
		case "drop_time": result.drop_time = number
		case "crouch_height": result.crouch_height = number
		case "crouch_speed": result.crouch_speed = number
		case "step_height": result.step_height = number
		case "dash_speed": result.dash_speed = number
		case "dash_duration": result.dash_duration = number
		case "dash_cooldown": result.dash_cooldown = number
		case "dash_chain_window": result.dash_chain_window = number
		case "dash_gravity_scale": result.dash_gravity_scale = number
		case "wall_slide_speed": result.wall_slide_speed = number
		case "wall_jump_speed_x": result.wall_jump_speed_x = number
		case "wall_jump_speed_y": result.wall_jump_speed_y = number
		case "wall_jump_lock_time": result.wall_jump_lock_time = number
		case: return {}, false
		}
	}
	return result, character_controller_2d_valid(result)
}

get_character_controller_2d :: proc(world: ^World, entity: Entity) -> (CharacterController2D, bool) {
	value, found := world.character_controllers_2d[entity]
	return value, found
}

set_character_controller_2d :: proc(world: ^World, entity: Entity, value: CharacterController2D) -> bool {
	if !has_component_data(world,entity,"CharacterController2D") || !character_controller_2d_valid(value) {return false}
	commit_component_value(world,entity,"CharacterController2D",&world.character_controllers_2d,value)
	return true
}

get_character_controller_2d_state :: proc(world: ^World, entity: Entity) -> (Character_Controller_State_2D, bool) {
	if !has_component_data(world,entity,"CharacterController2D") {return {}, false}
	return world.character_controller_states_2d[entity], true
}

// Movement persists until replaced. Jump requests are edges, latched until the
// next fixed simulation step. Send them from update or fixed_update, never draw.
character_controller_2d_move :: proc(world: ^World, entity: Entity, axis: f32) -> bool {
	if !has_component_data(world,entity,"CharacterController2D") || !is_enabled(world,entity) ||
		math.is_nan(axis) || math.is_inf(axis) {return false}
	state := world.character_controller_states_2d[entity]
	state.move_x = clamp(axis,-1,1)
	world.character_controller_states_2d[entity] = state
	return true
}

character_controller_2d_jump :: proc(world: ^World, entity: Entity) -> bool {
	if !has_component_data(world,entity,"CharacterController2D") || !is_enabled(world,entity) {return false}
	state := world.character_controller_states_2d[entity]
	state.jump_requested = true
	state.jump_buffer_released = false
	world.character_controller_states_2d[entity] = state
	return true
}

// A solid vertical capsule supplies the collision geometry. Extra sensors are
// allowed; other solid shapes would invalidate the capsule sweep used to snap.
character_controller_2d_ready :: proc(world: ^World, entity: Entity) -> bool {
	pose, has_pose := world.transforms[entity]
	body, has_body := world.rigid_bodies_2d[entity]
	capsule, has_capsule := world.capsule_colliders_2d[entity]
	if !has_pose || !has_body || !has_capsule || body.body_type != "dynamic" ||
		capsule.axis != .vertical || capsule.is_sensor || pose.scale[0] == 0 || pose.scale[1] == 0 {return false}
	if c,found := world.box_colliders_2d[entity]; found && !c.is_sensor {return false}
	if c,found := world.circle_colliders_2d[entity]; found && !c.is_sensor {return false}
	if c,found := world.polygon_colliders_2d[entity]; found && !c.is_sensor {return false}
	if c,found := world.segment_colliders_2d[entity]; found && !c.is_sensor {return false}
	a,b,radius := capsule_collider_2d_geometry(capsule,pose)
	return physics_query_vector_valid(a) && physics_query_vector_valid(b) && finite_nonnegative(radius) && radius > 0
}

Character_Contacts_2D :: struct {
	grounded: bool,
	normal: [2]f32,
	support_entity: Entity,
	support_component: string,
	support_velocity: [2]f32,
	block_left, block_right: bool,
}

character_contacts_2d :: proc(world: ^World, native: b2.BodyId, min_up: f32, preferred: Entity) -> Character_Contacts_2D {
	result: Character_Contacts_2D
	// Capacity is queried so crowded corners cannot hide a supporting contact.
	buffer := make([]b2.ContactData,int(b2.Body_GetContactCapacity(native)),context.temp_allocator)
	for contact in b2.Body_GetContactData(native,buffer) {
		touching := false
		for i in 0..<contact.manifold.pointCount {
			if contact.manifold.points[i].separation <= 0.05 {touching = true}
		}
		if !touching || !one_way_contact_2d(world,contact.shapeIdA,contact.shapeIdB,contact.manifold.normal) {continue}
		n := [2]f32{contact.manifold.normal.x,contact.manifold.normal.y}
		other := contact.shapeIdA
		if b2.ID_EQUALS(b2.Shape_GetBody(contact.shapeIdA),native) {n = -n; other = contact.shapeIdB}
		if -n[1] >= min_up {
			owner, known := physics_2d_entity_from_shape(world,other)
			if !known || !is_enabled(world,owner.entity) {continue}
			// Keep support stable at seams; break remaining ties by entity ID.
			equal_slope := math.abs(n[1]-result.normal[1]) < 0.0001
			prefer := owner.entity == preferred || (result.support_entity != preferred && owner.entity < result.support_entity)
			if !result.grounded || n[1] < result.normal[1]-0.0001 || (equal_slope && prefer) {
				result.normal = n
				result.support_entity = owner.entity
				result.support_component = owner.component
				result.support_velocity = character_support_velocity_2d(world,owner.entity)
			}
			result.grounded = true
		} else {
			if n[0] > 0.01 {result.block_left = true}
			if n[0] < -0.01 {result.block_right = true}
		}
	}
	return result
}

character_ground_cast_2d :: proc(world: ^World, entity: Entity, distance: f32) -> (Raycast_Hit_2D, bool) {
	if distance <= 0 {return {}, false}
	capsule,_ := get_effective_capsule_collider_2d(world,entity)
	pose := world.transforms[entity]
	a,b,radius := capsule_collider_2d_geometry(capsule,pose)
	query := Physics_Query_2D{caller_context=context,world=world,filter=Default_Physics_Query_Filter,respect_one_way=true}
	query.filter.ignore,query.filter.include_sensors = entity,false
	query.filter.layers,_ = entity_layer_mask(world,entity)
	proxy := b2.ShapeProxy{count=2,radius=radius}
	proxy.points[0],proxy.points[1] = {a[0],a[1]},{b[0],b[1]}
	_ = b2.World_CastShape(world.box2d_world,proxy,{0,distance},
		{categoryBits=query.filter.layers,maskBits=query.filter.layers},physics_2d_ray_result,&query)
	return query.hit,query.found
}

character_controllers_2d_before_step :: proc(world: ^World, dt: f32) {
	for entity, config in world.character_controllers_2d {
		if !is_enabled(world,entity) {continue}
		native,found := world.box2d_bodies[entity]
		if !found {continue}
		state := world.character_controller_states_2d[entity]
		state.stepped,state.step_support,state.step_component = false,0,""
		state.wall_jumped,state.wall_sliding = false,false
		state.dash_started,state.dash_ended,state.dash_blocked = false,false,false
		if !character_controller_2d_ready(world,entity) {
			if state.active {
				b2.Body_SetGravityScale(native,world.rigid_bodies_2d[entity].gravity_scale)
				shapes := make([]b2.ShapeId,int(b2.Body_GetShapeCount(native)),context.temp_allocator)
				for shape in b2.Body_GetShapes(native,shapes) {b2.Shape_SetFriction(shape,0.6)}
			}
			character_controller_2d_reset_state(world,entity)
			continue
		}
		just_activated := !state.active
		if !state.active {
			shapes := make([]b2.ShapeId,int(b2.Body_GetShapeCount(native)),context.temp_allocator)
			for shape in b2.Body_GetShapes(native,shapes) {b2.Shape_SetFriction(shape,0)}
			state.active = true
		}
		character_crouch_before_step_2d(world,entity,config,&state)
		world.character_controller_states_2d[entity] = state
		b2.Body_SetGravityScale(native,0) // The motor integrates its own gravity.
		character_drop_guard_2d(world,entity,&state,dt)
		world.character_controller_states_2d[entity] = state
		min_up := math.cos(config.max_slope_angle*math.PI/180)
		contacts: Character_Contacts_2D
		// Body_SetTransform leaves old manifolds until World_Step. Ignore them
		// on activation/reset so teleports cannot inherit support from elsewhere.
		if !just_activated && !state.ignore_contacts {contacts = character_contacts_2d(world,native,min_up,state.support_entity)}
		body := world.rigid_bodies_2d[entity]
		velocity := body.velocity
		if state.jumping && velocity[1] >= max(0,state.inherited_velocity[1]) {state.jumping = false}
		if !state.jumping && contacts.grounded {
			state.grounded,state.ground_normal = true,contacts.normal
			state.support_entity,state.support_velocity = contacts.support_entity,contacts.support_velocity
			state.support_component = contacts.support_component
		}
		if state.grounded {
			state.coyote_remaining = config.coyote_time
			// Query after all game systems have supplied this step's platform velocity.
			state.support_velocity = character_support_velocity_2d(world,state.support_entity)
		}
		if state.drop_requested {
			if state.grounded && one_way_enabled_2d(world,state.support_entity,state.support_component) {
				character_dash_cancel_2d(&state,config)
				state.drop_entity,state.drop_component = state.support_entity,state.support_component
				state.drop_remaining = config.drop_time
				velocity[1] = state.support_velocity[1]+config.drop_speed
				state.grounded,state.jumping = false,false
				state.support_entity,state.support_velocity,state.support_component = 0,{},""
				state.coyote_remaining,state.jump_buffer_remaining = 0,0
				state.jump_requested = false
				state.jump_release_requested,state.jump_buffer_released,state.jump_cut_available = false,false,false
			}
			state.drop_requested = false
		}
		if state.jump_requested {state.jump_buffer_remaining = config.jump_buffer_time}
		character_wall_refresh_2d(world,entity,config,&state)
		jump := (state.jump_requested || state.jump_buffer_remaining > 0) &&
			(state.grounded || state.coyote_remaining > 0) && config.jump_speed > 0
		wall_jump := !jump && (state.jump_requested || state.jump_buffer_remaining > 0) &&
			state.wall_entity != 0 && config.wall_jump_speed_x > 0 && config.wall_jump_speed_y > 0
		state.jump_requested = false
		if jump || wall_jump {character_dash_cancel_2d(&state,config)}
		character_dash_before_step_2d(&state,config,&velocity)
		acceleration := config.acceleration if state.grounded else config.air_acceleration
		speed := config.crouch_speed if state.crouched else config.move_speed
		target := state.move_x*speed
		relative_x := velocity[0]-state.inherited_velocity[0]
		if state.wall_jump_lock_remaining <= 0 || state.grounded {
			relative_x += clamp(target-relative_x,-acceleration*dt,acceleration*dt)
		}
		state.wall_jump_lock_remaining = max(0,state.wall_jump_lock_remaining-dt)
		if state.grounded {state.wall_jump_lock_remaining = 0}
		if state.grounded {state.inherited_velocity = state.support_velocity}
		if state.dashing {relative_x = state.dash_direction*config.dash_speed}
		velocity[0] = relative_x+state.inherited_velocity[0]
		if !state.dashing && !jump && !wall_jump && character_step_up_2d(world,entity,config,&state,velocity[0],dt,contacts) {
			contacts.block_left,contacts.block_right = false,false
		}
		if (velocity[0]<0 && contacts.block_left) || (velocity[0]>0 && contacts.block_right) {
			if state.dashing {state.dash_blocked = true; character_dash_finish_2d(&state,config)}
			velocity[0] = 0
			relative_x = -state.inherited_velocity[0]
			if !state.jumping && !state.grounded {velocity[1] = max(velocity[1],0)}
		}
		if jump || wall_jump {
			launch_speed := config.jump_speed
			if wall_jump {
				state.support_velocity = state.wall_velocity
				state.inherited_velocity = state.wall_velocity
				velocity[0] = state.wall_normal[0]*config.wall_jump_speed_x+state.wall_velocity[0]
				launch_speed = config.wall_jump_speed_y
				state.wall_jump_lock_remaining = config.wall_jump_lock_time
				state.wall_jumped = true
			}
			state.jump_launch_velocity_y = state.support_velocity[1]
			state.jump_cut_available,state.jump_cut_applied = true,false
			// A release attached to this buffered press follows it to launch.
			// An older jump's release must not cut a newer held press.
			state.jump_release_requested = state.jump_buffer_released
			state.jump_buffer_released = false
			velocity[1] = -launch_speed+state.support_velocity[1]
			state.support_entity,state.support_velocity,state.support_component = 0,{},""
			state.grounded,state.jumping = false,true
			state.coyote_remaining,state.jump_buffer_remaining = 0,0
		} else if state.grounded {
			velocity[1] = state.support_velocity[1]-state.ground_normal[0]*relative_x/state.ground_normal[1]
		} else {
			gravity_scale: f32 = config.dash_gravity_scale if state.dashing else 1
			if state.dashing && gravity_scale == 0 {velocity[1] = min(state.inherited_velocity[1],config.max_fall_speed)}
			else {velocity[1] = min(velocity[1]+config.gravity*gravity_scale*dt,config.max_fall_speed)}
		}
		character_jump_release_2d(&state,config,&velocity)
		if !state.dashing && !jump && !wall_jump && state.wall_entity != 0 && config.wall_slide_speed > 0 && velocity[1] > state.wall_velocity[1] {
			velocity[1] = min(velocity[1],min(config.max_fall_speed,state.wall_velocity[1]+config.wall_slide_speed))
			state.wall_sliding = true
		}
		state.jump_buffer_remaining = max(0,state.jump_buffer_remaining-dt)
		if state.jump_buffer_remaining == 0 {state.jump_buffer_released = false}
		if !state.grounded {
			state.coyote_remaining = max(0,state.coyote_remaining-dt)
			if state.coyote_remaining == 0 {state.support_entity,state.support_velocity,state.support_component = 0,{},""}
		}
		state.velocity_x_before_step,state.velocity_y_before_step = velocity[0],velocity[1]
		world.character_controller_states_2d[entity] = state
		body.velocity,body.grounded = velocity,state.grounded
		if world.rigid_bodies_2d[entity] != body {record_component_change(world,entity,"RigidBody2D",.Changed)}
		world.rigid_bodies_2d[entity] = body
		b2.Body_SetLinearVelocity(native,{velocity[0],velocity[1]})
	}
}

character_controllers_2d_after_step :: proc(world: ^World, dt: f32) {
	for entity, config in world.character_controllers_2d {
		state := world.character_controller_states_2d[entity]
		if !state.active || !is_enabled(world,entity) {continue}
		native,found := world.box2d_bodies[entity]
		if !found {continue}
		body := world.rigid_bodies_2d[entity]
		if state.jumping && body.velocity[1] >= max(0,state.inherited_velocity[1]) {state.jumping = false}
		min_up := math.cos(config.max_slope_angle*math.PI/180)
		contacts := character_contacts_2d(world,native,min_up,state.support_entity)
		character_step_contact_2d(world,entity,&state,&contacts)
		// A jump can descend in world space while rising relative to its source.
		// A different (or reversing) support can still catch it. Compare incoming
		// velocity with that actual support, before the solver equalized them.
		if state.jumping && contacts.grounded && state.velocity_y_before_step >= contacts.support_velocity[1] {
			state.jumping = false
		}
		was_grounded := state.grounded
		state.grounded = !state.jumping && contacts.grounded
		state.ground_normal = {}
		state.ignore_contacts = false // World_Step refreshed any invalidated manifolds.
		if state.grounded {
			state.ground_normal = contacts.normal
			state.support_entity,state.support_velocity = contacts.support_entity,contacts.support_velocity
			state.support_component = contacts.support_component
		}
		if !state.grounded && !state.jumping {
			// Long snaps only maintain existing support. Falling characters must
			// reach the ground, so snap distance cannot grant an early air jump.
			distance: f32 = config.ground_snap_distance if was_grounded else 0.05
			if state.posture_changed {distance = max(distance,0.05)}
			hit,ok := character_ground_cast_2d(world,entity,distance)
			if ok && -hit.normal[1] >= min_up {
				pose := world.transforms[entity]
				pose.position[1] += max(0,distance*hit.fraction-0.005)
				world.transforms[entity] = pose
				record_component_change(world,entity,"Transform",.Changed)
				b2.Body_SetTransform(native,{pose.position[0],pose.position[1]},b2.Body_GetRotation(native))
				state.grounded,state.ground_normal = true,hit.normal
				state.support_entity = hit.entity
				state.support_component = hit.component
				state.support_velocity = character_support_velocity_2d(world,hit.entity)
			}
		}
		if state.grounded || !state.jumping || body.velocity[1] >= state.jump_launch_velocity_y {state.jump_cut_available = false}
		state.posture_changed = false
		if state.grounded {state.coyote_remaining = config.coyote_time}
		if state.grounded {state.wall_jump_lock_remaining = 0}
		character_dash_after_step_2d(&state,config,contacts,dt)
		character_wall_refresh_2d(world,entity,config,&state)
		if state.wall_entity == 0 {state.wall_sliding = false}
		body.grounded = state.grounded
		if world.rigid_bodies_2d[entity] != body {record_component_change(world,entity,"RigidBody2D",.Changed)}
		world.rigid_bodies_2d[entity] = body
		world.character_controller_states_2d[entity] = state
	}
}
