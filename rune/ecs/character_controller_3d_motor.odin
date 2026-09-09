package ecs

import "core:math"
import b3 "vendor:box3d"

character_approach_3d :: proc(current,target:[3]f32,amount:f32)->[3]f32 {
	difference := target-current
	length := character_length_3d(difference)
	if length <= amount || length == 0 {return target}
	return current+difference*(amount/length)
}
character_support_3d :: proc(world:^World,state:^Character_Controller_State_3D,hit:Raycast_Hit_3D,position:[3]f32) {
	state.support_entity = hit.entity
	state.ground_normal = hit.normal
	state.support_world_point = position
	if native,valid := physics_3d_native_body(world,hit.entity); valid {
		point := b3.Pos{position[0],position[1],position[2]}
		state.support_local_point = character_array_3d(b3.Body_GetLocalPoint(native,point))
		state.support_velocity = character_array_3d(b3.Body_GetWorldPointVelocity(native,point))
	} else {state.support_entity=0;state.support_velocity={}}
}

character_push_3d :: proc(query:^Character_Plane_Query_3D,position,velocity:[3]f32,force,dt:f32,support:Entity) {
	if force == 0 {return}
	for plane,i in query.planes {
		owner := query.owners[i]
		if owner == support || plane.plane.offset < -0.01 {continue}
		duplicate := false
		for j in 0..<i {if query.owners[j] == owner {duplicate=true;break}}
		if duplicate {continue}
		native,valid := physics_3d_native_body(query.world,owner)
		if !valid || b3.Body_GetType(native) != .dynamicBody {continue}
		normal := character_array_3d(plane.plane.normal)
		normal[1]=0
		length := character_length_3d(normal)
		if length < 0.01 {continue}
		normal /= length
		point := position+query.points[i]
		native_point := b3.Pos{point[0],point[1],point[2]}
		relative := velocity-character_array_3d(b3.Body_GetWorldPointVelocity(native,native_point))
		if character_dot_3d(relative,normal) >= 0 {continue}
		b3.Body_ApplyLinearImpulse(native,character_vec_3d(-normal*force*dt),native_point,true)
	}
}

// Called once after each native 3D step. The mover is a query capsule, not a rigid body.
character_controllers_3d_step :: proc(world:^World,dt:f32) {
	query := Character_Plane_Query_3D{caller_context=context,world=world}
	defer delete(query.planes)
	defer delete(query.owners)
	defer delete(query.points)
	for entity,config in world.character_controllers_3d {
		if !character_controller_3d_ready(world,entity) {
			delete_key(&world.character_controller_states_3d,entity)
			continue
		}
		query.entity=entity
		state := world.character_controller_states_3d[entity]
		pose := world.transforms[entity]
		position := pose.position
		state.previous_position=position
		if !state.active {state.height=config.height;state.active=true}
		state.stepped,state.stand_blocked=false,false
		min_up := math.cos(config.max_slope_angle*Radians_Per_Degree)
		query.min_up=min_up
		was_grounded := state.grounded

		// Follow the previous contact point, including platform rotation. Sweep
		// the carry so a moving support cannot carry the capsule through a wall.
		if state.grounded && state.support_entity != 0 {
			native,valid := physics_3d_native_body(world,state.support_entity)
			if valid && is_enabled(world,state.support_entity) {
				point := b3.Body_GetWorldPoint(native,character_vec_3d(state.support_local_point))
				current := [3]f32{f32(point.x),f32(point.y),f32(point.z)}
				displacement := current-state.support_world_point
				state.support_velocity = displacement/dt
				position=character_slide_3d(&query,position,displacement,config.radius,state.height)
			} else {state.grounded=false;state.support_entity=0;state.support_velocity={}}
		}
		// Feet stay fixed when changing posture. A taller capsule must fit first.
		requested_height := config.crouch_height if state.crouch_requested else config.height
		if requested_height > state.height {
			state.stand_blocked=!character_clearance_3d(world,entity,position,config.radius,requested_height)
		}
		if !state.stand_blocked {state.height=requested_height}
		state.crouched=state.height < config.height-0.001

		probe_distance := f32(0.04)
		if was_grounded {probe_distance=max(probe_distance,config.ground_snap_distance)}
		if state.velocity[1] <= 0 || state.grounded {
			hit,landing,grounded := character_ground_3d(world,entity,position,config.radius,state.height,probe_distance,min_up)
			state.grounded=grounded
			if grounded {position=landing;character_support_3d(world,&state,hit,position)}
		} else {state.grounded=false}
		if was_grounded && !state.grounded {
			state.velocity+=state.support_velocity
			state.inherited_velocity=state.support_velocity
		}
		if state.grounded {
			state.coyote_remaining=config.coyote_time
			state.inherited_velocity=state.support_velocity
		} else {state.coyote_remaining=max(0,state.coyote_remaining-dt)}
		if state.jump_requested {state.jump_buffer_remaining=config.jump_buffer_time+dt}
		else {state.jump_buffer_remaining=max(0,state.jump_buffer_remaining-dt)}
		state.jump_requested=false

		speed := config.move_speed
		if state.crouched {speed=config.crouch_speed}
		else if state.sprint_requested {speed*=config.sprint_multiplier}
		desired := [3]f32{state.move[0]*speed,0,state.move[1]*speed}
		horizontal := [3]f32{state.velocity[0],0,state.velocity[2]}
		acceleration := config.air_acceleration
		if state.grounded {
			acceleration=config.acceleration
			if state.move == ([2]f32{}) {acceleration=config.braking}
		} else {
			desired[0]+=state.inherited_velocity[0]
			desired[2]+=state.inherited_velocity[2]
		}
		horizontal=character_approach_3d(horizontal,desired,acceleration*dt)
		state.velocity[0],state.velocity[2]=horizontal[0],horizontal[2]
		if state.grounded {
			tangent := horizontal-state.ground_normal*character_dot_3d(horizontal,state.ground_normal)
			length := character_length_3d(tangent)
			if length > 0.0001 {tangent*=character_length_3d(horizontal)/length}
			state.velocity=tangent
			state.jump_cut_available=false
		} else {state.velocity[1]=max(-config.max_fall_speed,state.velocity[1]-config.gravity*dt)}

		jumped := false
		if state.jump_buffer_remaining > 0 && (state.grounded || state.coyote_remaining > 0) {
			if state.grounded {
				state.velocity[0]+=state.support_velocity[0]
				state.velocity[2]+=state.support_velocity[2]
			}
			state.velocity[1]=config.jump_speed+state.inherited_velocity[1]
			state.grounded=false
			state.support_entity=0
			state.coyote_remaining,state.jump_buffer_remaining=0,0
			state.jump_cut_available=true
			jumped=true
		}
		if state.jump_cut_available && (state.jump_release_requested || (jumped && state.jump_buffer_released)) {
			relative_up := state.velocity[1]-state.inherited_velocity[1]
			if relative_up > 0 {state.velocity[1]=state.inherited_velocity[1]+relative_up*config.jump_cut_multiplier}
			state.jump_cut_available=false
		}
		state.jump_release_requested=false
		start := position
		translation := state.velocity*dt
		position=character_slide_3d(&query,position,translation,config.radius,state.height)
		if state.grounded && !jumped {
			position,state.stepped=character_try_step_3d(&query,start,translation,position,config,state.height,min_up)
		}
		// Preserve vertical velocity on slopes but cancel a jump at a ceiling.
		character_collect_planes_3d(&query,position,config.radius,state.height)
		character_push_3d(&query,position,state.velocity,config.push_force,dt,state.support_entity)
		for plane in query.planes {
			if plane.plane.offset < -0.01 {continue}
			normal:=character_array_3d(plane.plane.normal)
			if normal[1] < -0.1 && state.velocity[1] > 0 {state.velocity[1]=0}
		}
		if !jumped && (state.grounded || state.velocity[1] <= 0) {
			distance := f32(0.04)
			if state.grounded {distance=max(distance,config.ground_snap_distance)}
			hit,landing,grounded:=character_ground_3d(world,entity,position,config.radius,state.height,distance,min_up)
			if grounded {
				position=landing
				state.velocity[1]=0
				state.inherited_velocity={}
				character_support_3d(world,&state,hit,position)
			} else if state.grounded {
				state.velocity+=state.support_velocity
				state.inherited_velocity=state.support_velocity
			}
			state.grounded=grounded
		}
		if !state.grounded {state.support_entity=0;state.ground_normal={}}
		pose.position=position
		// Simulation writes bypass authored teleport/reset notifications.
		if world.transforms[entity] != pose {record_component_change(world,entity,"Transform",.Changed)}
		world.transforms[entity]=pose
		world.character_controller_states_3d[entity]=state
	}
}
