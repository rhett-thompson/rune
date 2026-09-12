package ecs

import "core:encoding/json"
import "core:math"

// World-space dimensions; Transform.position is the feet. Camera/input are game-owned.
CharacterController3D :: struct {
	radius, height, crouch_height: f32,
	move_speed, sprint_multiplier, crouch_speed: f32,
	acceleration, braking, air_acceleration: f32,
	gravity, jump_speed, jump_cut_multiplier, max_fall_speed: f32,
	max_slope_angle, ground_snap_distance, step_height: f32,
	coyote_time, jump_buffer_time: f32,
	// Maximum horizontal force applied to dynamic obstacles; zero disables pushing.
	push_force: f32,
}

Character_Controller_State_3D :: struct {
	active, grounded, crouched, stand_blocked, stepped: bool,
	velocity, ground_normal: [3]f32,
	previous_position: [3]f32,
	height: f32,
	support_entity: Entity,
	support_local_point, support_world_point, support_velocity: [3]f32,
	inherited_velocity: [3]f32,
	move: [2]f32,
	sprint_requested, crouch_requested: bool,
	jump_requested, jump_release_requested, jump_cut_available, jump_buffer_released: bool,
	coyote_remaining, jump_buffer_remaining: f32,
}

default_character_controller_3d :: proc() -> CharacterController3D {
	return {radius=0.35, height=1.8, crouch_height=1.0,
		move_speed=5, sprint_multiplier=1.8, crouch_speed=2.5,
		acceleration=35, braking=45, air_acceleration=10,
		gravity=24, jump_speed=8, jump_cut_multiplier=0.5, max_fall_speed=45,
		max_slope_angle=45, ground_snap_distance=0.2, step_height=0.3,
		coyote_time=0.1, jump_buffer_time=0.1, push_force=50}
}

character_controller_3d_valid :: proc(value: CharacterController3D) -> bool {
	for number in ([19]f32{value.radius,value.height,value.crouch_height,value.move_speed,value.sprint_multiplier,value.crouch_speed,value.acceleration,value.braking,value.air_acceleration,value.gravity,value.jump_speed,value.jump_cut_multiplier,value.max_fall_speed,value.max_slope_angle,value.ground_snap_distance,value.step_height,value.coyote_time,value.jump_buffer_time,value.push_force}) {
		if !finite_nonnegative(number) {return false}
	}
	return value.radius > 0 && value.height >= 2*value.radius &&
		value.crouch_height >= 2*value.radius && value.crouch_height <= value.height &&
		value.acceleration > 0 && value.braking > 0 && value.gravity > 0 && value.max_fall_speed > 0 &&
		value.sprint_multiplier >= 1 && value.max_slope_angle < 89 &&
		value.jump_cut_multiplier <= 1 && value.coyote_time <= 1 && value.jump_buffer_time <= 1 &&
		value.step_height < value.height
}

character_controller_3d_from_json :: proc(data: json.Value) -> (CharacterController3D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := default_character_controller_3d()
	for key, value in object {
		number, valid := read_number(value)
		if !valid {return {}, false}
		switch key {
		case "radius": result.radius = number
		case "height": result.height = number
		case "crouch_height": result.crouch_height = number
		case "move_speed": result.move_speed = number
		case "sprint_multiplier": result.sprint_multiplier = number
		case "crouch_speed": result.crouch_speed = number
		case "acceleration": result.acceleration = number
		case "braking": result.braking = number
		case "air_acceleration": result.air_acceleration = number
		case "gravity": result.gravity = number
		case "jump_speed": result.jump_speed = number
		case "jump_cut_multiplier": result.jump_cut_multiplier = number
		case "max_fall_speed": result.max_fall_speed = number
		case "max_slope_angle": result.max_slope_angle = number
		case "ground_snap_distance": result.ground_snap_distance = number
		case "step_height": result.step_height = number
		case "coyote_time": result.coyote_time = number
		case "jump_buffer_time": result.jump_buffer_time = number
		case "push_force": result.push_force = number
		case: return {}, false
		}
	}
	return result, character_controller_3d_valid(result)
}

get_character_controller_3d :: proc(world: ^World, entity: Entity) -> (CharacterController3D, bool) {
	value, found := world.character_controllers_3d[entity]
	return value, found
}
set_character_controller_3d :: proc(world: ^World, entity: Entity, value: CharacterController3D) -> bool {
	if !has_component_data(world,entity,"CharacterController3D") || !character_controller_3d_valid(value) {return false}
	commit_component_value(world,entity,"CharacterController3D",&world.character_controllers_3d,value)
	return true
}
get_character_controller_3d_state :: proc(world: ^World, entity: Entity) -> (Character_Controller_State_3D, bool) {
	if !has_component_data(world,entity,"CharacterController3D") {return {},false}
	return world.character_controller_states_3d[entity],true
}
character_controller_3d_ready :: proc(world: ^World, entity: Entity) -> bool {
	pose, found := world.transforms[entity]
	if !found || !has_component_data(world,entity,"CharacterController3D") || !is_enabled(world,entity) ||
		pose.scale != ([3]f32{1,1,1}) || world.parents[entity] != 0 {return false}
	// The query capsule owns movement; a native rigid body must not also write this transform.
	return !has_component_data(world,entity,"RigidBody3D") &&
		!has_component_data(world,entity,"BoxCollider") && !has_component_data(world,entity,"SphereCollider") &&
		!has_component_data(world,entity,"CharacterController")
}

// Teleport to a clear feet position, discarding velocity, support, and buffered
// input. The caller chooses a safe destination; this does not sweep the route.
character_controller_3d_teleport :: proc(world:^World,entity:Entity,position:[3]f32) -> bool {
	if !character_controller_3d_ready(world,entity) || !physics_query_vector_valid(position) {return false}
	pose:=world.transforms[entity];pose.position=position
	if !set_transform(world,entity,pose) {return false}
	delete_key(&world.character_controller_states_3d,entity)
	return true
}

// Direction is world X/Z, preserves analog strength, and persists until replaced.
character_controller_3d_move :: proc(world: ^World, entity: Entity, direction: [2]f32, sprint := false) -> bool {
	if !has_component_data(world,entity,"CharacterController3D") || !is_enabled(world,entity) || !physics_query_vector_valid(direction) {return false}
	state := world.character_controller_states_3d[entity]
	magnitude := math.sqrt(direction[0]*direction[0]+direction[1]*direction[1])
	state.move = direction
	if magnitude > 1 {state.move /= magnitude}
	state.sprint_requested = sprint
	world.character_controller_states_3d[entity] = state
	return true
}
character_controller_3d_jump :: proc(world: ^World, entity: Entity) -> bool {
	if !has_component_data(world,entity,"CharacterController3D") || !is_enabled(world,entity) {return false}
	state := world.character_controller_states_3d[entity]
	state.jump_requested, state.jump_buffer_released = true, false
	world.character_controller_states_3d[entity] = state
	return true
}
character_controller_3d_release_jump :: proc(world: ^World, entity: Entity) -> bool {
	if !has_component_data(world,entity,"CharacterController3D") || !is_enabled(world,entity) {return false}
	state := world.character_controller_states_3d[entity]
	state.jump_release_requested = true
	state.jump_buffer_released = true
	world.character_controller_states_3d[entity] = state
	return true
}
character_controller_3d_crouch :: proc(world: ^World, entity: Entity, crouch: bool) -> bool {
	if !has_component_data(world,entity,"CharacterController3D") || !is_enabled(world,entity) {return false}
	state := world.character_controller_states_3d[entity]
	state.crouch_requested = crouch
	world.character_controller_states_3d[entity] = state
	return true
}
