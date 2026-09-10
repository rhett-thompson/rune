package main

import "core:math"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:input"

// Movement dimensions and speeds belong to CharacterController3D. The game owns
// its camera and visuals, leaving the motor's unit-scale feet transform alone.
Third_Person_Settings :: struct {
	mouse_sensitivity, zoom_speed: f32,
	initial_yaw, initial_pitch, distance, min_distance, max_distance: f32,
	target_height_ratio, camera_smoothing, collision_margin, turn_speed: f32,
	footstep_stride: f32,
}

Third_Person_Defaults :: Third_Person_Settings {
	mouse_sensitivity = 0.25,
	zoom_speed = 0.8,
	initial_yaw = 180,
	initial_pitch = 22,
	distance = 6,
	min_distance = 2,
	max_distance = 12,
	target_height_ratio = 0.65,
	camera_smoothing = 12,
	collision_margin = 0.2,
	turn_speed = 12,
	footstep_stride = 2.4,
}

Camera_State :: struct {
	initialized, obstructed: bool,
	yaw, pitch, distance, actual_distance, target_height: f32,
	authored_distance: f32,
}
camera_state: Camera_State
facing_yaw: f32
jump_press_sent, jump_release_sent: bool

sample_controls :: proc(game: ^rune.Engine, world: ^ecs.World) {
	jump_press_sent, jump_release_sent = false, false
	if rune.is_paused(game) || console.is_open(rune.developer_console(game)) {
		suspend_interactions(game)
		ecs.character_controller_3d_move(world, player, {})
		return
	}
	settings, found := ecs.get(world, player, Third_Person_Settings)
	if !found {return}
	controls := rune.input_state(game)
	min_distance := max(settings.min_distance, 0.5)
	max_distance := max(settings.max_distance, min_distance)
	camera_state.distance = clamp(camera_state.distance-input.axis(controls, "zoom")*max(settings.zoom_speed, 0),
		min_distance, max_distance)
	if input.is_down(controls, "orbit_camera") || input.is_down(controls, "orbit_with_character") {
		camera_state.yaw -= input.axis(controls, "look_x")*settings.mouse_sensitivity
		camera_state.pitch = clamp(camera_state.pitch+input.axis(controls, "look_y")*settings.mouse_sensitivity, -15, 75)
	}
	submit_movement(game, world)
}

// Fixed callbacks also see injected console input. Guards consume each jump edge
// only once when several physics steps occur in one rendered frame.
submit_movement :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if console.is_open(rune.developer_console(game)) {
		ecs.character_controller_3d_move(world, player, {})
		return
	}
	controls := rune.input_state(game)
	yaw := camera_state.yaw*f32(math.PI/180)
	forward := [2]f32{math.sin(yaw), math.cos(yaw)}
	right := [2]f32{-forward[1], forward[0]}
	direction := forward*input.axis(controls, "move_z")+right*input.axis(controls, "move_x")
	ecs.character_controller_3d_move(world, player, direction, input.is_down(controls, "sprint"))
	ecs.character_controller_3d_crouch(world, player, input.is_down(controls, "crouch"))
	if !jump_press_sent && input.pressed(controls, "jump") {
		ecs.character_controller_3d_jump(world, player)
		jump_press_sent = true
	}
	if !jump_release_sent && input.released(controls, "jump") {
		ecs.character_controller_3d_release_jump(world, player)
		jump_release_sent = true
	}
}

update_avatar_part :: proc(world: ^ecs.World, entity: ecs.Entity, position, scale: [3]f32, yaw: f32) {
	pose, found := ecs.get_transform(world, entity)
	if !found {return}
	pose.position = position
	pose.scale = scale
	pose.rotation = {0, yaw, 0}
	ecs.set_transform(world, entity, pose)
}

update_camera :: proc(game: ^rune.Engine, world: ^ecs.World) {
	feet, found := ecs.get_transform(world, player)
	settings, configured := ecs.get(world, player, Third_Person_Settings)
	camera, has_camera := ecs.get_camera_3d(world, follow_camera)
	camera_pose, has_pose := ecs.get_transform(world, follow_camera)
	config, has_config := ecs.get_character_controller_3d(world, player)
	if !found || !configured || !has_camera || !has_pose || !has_config {return}
	motor, _ := ecs.get_character_controller_3d_state(world, player)
	height := config.height
	position := feet.position
	if motor.active {
		height = motor.height
		alpha := clamp(game.fixed_accumulator/game.fixed_delta_time, 0, 1)
		position = motor.previous_position+(feet.position-motor.previous_position)*alpha
	}
	target_height := height*clamp(settings.target_height_ratio, 0.1, 0.9)
	min_distance := max(settings.min_distance, 0.5)
	max_distance := max(settings.max_distance, min_distance)
	if !camera_state.initialized {
		camera_state = {
			initialized = true,
			yaw = settings.initial_yaw,
			pitch = clamp(settings.initial_pitch, -15, 75),
			distance = clamp(settings.distance, min_distance, max_distance),
			actual_distance = clamp(settings.distance, min_distance, max_distance),
			target_height = target_height,
			authored_distance = settings.distance,
		}
	}
	// A value-only reload of distance takes effect without resetting orbit yaw.
	if camera_state.authored_distance != settings.distance {
		camera_state.distance = settings.distance
		camera_state.authored_distance = settings.distance
	}
	camera_state.distance = clamp(camera_state.distance, min_distance, max_distance)
	blend := 1-math.exp(-max(settings.camera_smoothing, 0.1)*game.delta_time)
	camera_state.target_height += (target_height-camera_state.target_height)*blend
	// Keep the pivot inside a suddenly shortened capsule under a low roof.
	camera_state.target_height = min(camera_state.target_height, height*0.9)
	target := position+[3]f32{0, camera_state.target_height, 0}
	yaw, pitch := camera_state.yaw*f32(math.PI/180), camera_state.pitch*f32(math.PI/180)
	backward := [3]f32{-math.sin(yaw)*math.cos(pitch), math.sin(pitch), -math.cos(yaw)*math.cos(pitch)}
	allowed_distance := camera_state.distance
	filter := ecs.Default_Physics_Query_Filter
	filter.ignore = player
	filter.include_sensors = false
	filter.layers, _ = ecs.entity_layer_mask(world, player)
	// A center ray and four offset rays leave room around the lens. This is a
	// small camera obstruction probe, not a full swept camera collider.
	margin := clamp(settings.collision_margin, 0.05, 0.5)
	offsets := [5][3]f32{{}, {margin, 0, 0}, {-margin, 0, 0}, {0, margin, 0}, {0, -margin, 0}}
	for offset in offsets {
		hit, blocked := ecs.physics_3d_raycast(world, target+offset, backward*camera_state.distance, filter)
		if blocked {allowed_distance = min(allowed_distance, max(0.05, camera_state.distance*hit.fraction-margin))}
	}
	camera_state.obstructed = allowed_distance < camera_state.distance
	if allowed_distance < camera_state.actual_distance {
		camera_state.actual_distance = allowed_distance
	} else {
		camera_state.actual_distance += (allowed_distance-camera_state.actual_distance)*blend
	}
	camera_pose.position = target+backward*camera_state.actual_distance
	camera.target = target
	ecs.set_transform(world, follow_camera, camera_pose)
	ecs.set_camera_3d(world, follow_camera, camera)
	// Tight spaces can retract the camera into the character. Keep the course
	// visible, restoring the avatar as soon as the camera has room again.
	avatar_visible := camera_state.actual_distance >= 1.5
	parts := [3]ecs.Entity{avatar_body, avatar_head, avatar_front}
	for part in parts {
		ecs.set_enabled(world, part, avatar_visible)
	}

	desired_yaw := facing_yaw
	controls := rune.input_state(game)
	if input.is_down(controls, "orbit_with_character") {
		desired_yaw = camera_state.yaw
	} else if motor.move[0]*motor.move[0]+motor.move[1]*motor.move[1] > 0.001 {
		desired_yaw = math.atan2(motor.move[0], motor.move[1])*f32(180/math.PI)
	}
	angle := (desired_yaw-facing_yaw)*f32(math.PI/180)
	shortest := math.atan2(math.sin(angle), math.cos(angle))*f32(180/math.PI)
	facing_yaw += shortest*(1-math.exp(-max(settings.turn_speed, 0.1)*game.delta_time))
	// Children use local offsets; compensate for fixed-step interpolation without
	// writing to the motor Transform or scaling its collision capsule.
	local_feet := position-feet.position
	torso_height := max(height-0.38, 0.2)
	update_avatar_part(world, avatar_body, local_feet+[3]f32{0, torso_height*0.5, 0}, {0.55, torso_height, 0.4}, facing_yaw)
	update_avatar_part(world, avatar_head, local_feet+[3]f32{0, height-0.19, 0}, {1, 1, 1}, facing_yaw)
	facing := facing_yaw*f32(math.PI/180)
	update_avatar_part(world, avatar_front, local_feet+[3]f32{math.sin(facing)*0.18, height-0.19, math.cos(facing)*0.18},
		{0.28, 0.1, 0.07}, facing_yaw)
}
