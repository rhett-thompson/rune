package main

import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"

// Camera tuning stays game-owned; movement tuning is CharacterController3D.
First_Person_Settings :: struct {
	mouse_sensitivity, eye_inset: f32,
	crouch_transition_time: f32,
	footstep_stride: f32,
	head_bob_enabled: bool,
	head_bob_vertical, head_bob_horizontal: f32,
	head_bob_frequency, head_bob_smoothing: f32,
}

First_Person_Defaults :: First_Person_Settings {
	mouse_sensitivity = 0.15,
	eye_inset = 0.2,
	crouch_transition_time = 0.18,
	footstep_stride = 2.4,
	head_bob_enabled = true,
	head_bob_vertical = 0.018,
	head_bob_horizontal = 0.009,
	head_bob_frequency = 1.8,
	head_bob_smoothing = 12,
}

Camera_Height_Transition :: struct {
	initialized: bool,
	current, start, target, elapsed: f32,
}
camera_height: Camera_Height_Transition

update_camera_height :: proc(state: ^Camera_Height_Transition, target, duration, dt: f32) -> f32 {
	if !state.initialized || duration <= 0 {
		state^ = {initialized = true, current = target, start = target, target = target}
		return target
	}
	if target != state.target {
		// Reverse from the current visible height if crouch is toggled mid-transition.
		state.start = state.current
		state.target = target
		state.elapsed = 0
	}
	state.elapsed = min(state.elapsed+max(dt, 0), duration)
	t := state.elapsed/duration
	ease := t*t*(3-2*t)
	state.current = state.start+(state.target-state.start)*ease
	return state.current
}

Head_Bob :: struct {
	phase: f32,
	offset: [2]f32, // Camera-local horizontal sway and vertical bob.
}
head_bob: Head_Bob

update_head_bob :: proc(bob: ^Head_Bob, settings: First_Person_Settings, speed_ratio, dt: f32) -> [2]f32 {
	if !settings.head_bob_enabled {
		bob^ = {}
		return {}
	}
	if dt <= 0 {return bob.offset}
	pace := clamp(speed_ratio, 0, 2)
	target: [2]f32
	if pace > 0.01 && settings.head_bob_frequency > 0 {
		// One vertical cycle per footfall, with sway alternating between feet.
		bob.phase = math.mod(bob.phase + 2*f32(math.PI)*settings.head_bob_frequency*pace*dt, 4*f32(math.PI))
		strength := min(pace, 1)
		target = {
			math.sin(bob.phase*0.5)*max(settings.head_bob_horizontal, 0)*strength,
			math.sin(bob.phase)*max(settings.head_bob_vertical, 0)*strength,
		}
	}
	blend := 1 - math.exp(-max(settings.head_bob_smoothing, 0.1)*dt)
	bob.offset += (target-bob.offset)*blend
	if (target == [2]f32{}) && math.abs(bob.offset[0])+math.abs(bob.offset[1]) < 0.00001 {
		bob^ = {}
	}
	return bob.offset
}

jump_press_sent, jump_release_sent: bool

sample_controls :: proc(game:^rune.Engine,world:^ecs.World) {
	jump_press_sent,jump_release_sent=false,false
	controls:=rune.input_state(game)
	if input.pressed(controls,"toggle_cursor") {toggle_cursor()}
	if !cursor_captured || rune.is_paused(game) {
		ecs.character_controller_3d_move(world,player,{})
		if !cursor_captured {ecs.character_controller_3d_release_jump(world,player)}
		return
	}
	settings,found:=ecs.get(world,player,First_Person_Settings)
	if !found {return}
	camera_yaw+=input.axis(controls,"look_x")*settings.mouse_sensitivity
	camera_pitch=clamp(camera_pitch+input.axis(controls,"look_y")*settings.mouse_sensitivity,-89,89)
	submit_movement(game,world)
}

// Also called from fixed_update after developer-console input overrides.
// Edge guards prevent repeated jump presses within a rendered frame.
submit_movement :: proc(game:^rune.Engine,world:^ecs.World) {
	controls:=rune.input_state(game)
	if !cursor_captured {ecs.character_controller_3d_move(world,player,{});return}
	radians:=camera_yaw*f32(math.PI/180)
	// Yaw alone controls movement: looking up/down never changes walking speed.
	forward:=[2]f32{math.sin(radians),math.cos(radians)}
	right:=[2]f32{-forward[1],forward[0]}
	direction:=forward*input.axis(controls,"move_z")+right*input.axis(controls,"move_x")
	ecs.character_controller_3d_move(world,player,direction,input.is_down(controls,"sprint"))
	ecs.character_controller_3d_crouch(world,player,input.is_down(controls,"crouch"))
	if !jump_press_sent && input.pressed(controls,"jump") {ecs.character_controller_3d_jump(world,player);jump_press_sent=true}
	if !jump_release_sent && input.released(controls,"jump") {ecs.character_controller_3d_release_jump(world,player);jump_release_sent=true}
}

update_camera :: proc(game:^rune.Engine,world:^ecs.World) {
	feet,found:=ecs.get_transform(world,player)
	settings,configured:=ecs.get(world,player,First_Person_Settings)
	camera,has_camera:=ecs.get_camera_3d(world,camera_entity)
	camera_pose,has_pose:=ecs.get_transform(world,camera_entity)
	config,has_config:=ecs.get_character_controller_3d(world,player)
	if !found || !configured || !has_camera || !has_pose || !has_config {return}
	motor,_:=ecs.get_character_controller_3d_state(world,player)
	height:=config.height
	position:=feet.position
	if motor.active {
		height=motor.height
		alpha:=clamp(game.fixed_accumulator/game.fixed_delta_time,0,1)
		position=motor.previous_position+(feet.position-motor.previous_position)*alpha
	}
	speed_ratio: f32
	if motor.active && motor.grounded && (motor.move[0] != 0 || motor.move[1] != 0) && game.fixed_delta_time > 0 {
		// Use resolved motion instead of requested velocity, excluding support carry.
		motion := (feet.position-motor.previous_position)/game.fixed_delta_time-motor.support_velocity
		speed := math.sqrt(motion[0]*motion[0]+motion[2]*motion[2])
		speed_ratio = speed/max(config.move_speed, 0.001)
	} else if !motor.active {
		head_bob = {}
		camera_height = {}
	}
	eye_height := update_camera_height(&camera_height, max(config.radius, height-settings.eye_inset), settings.crouch_transition_time, game.delta_time)
	bob := update_head_bob(&head_bob, settings, speed_ratio, game.delta_time)
	yaw,pitch:=camera_yaw*f32(math.PI/180),camera_pitch*f32(math.PI/180)
	right := [3]f32{-math.cos(yaw), 0, math.sin(yaw)}
	camera_pose.position=position+[3]f32{0,eye_height+bob[1],0}+right*bob[0]
	forward:=[3]f32{math.sin(yaw)*math.cos(pitch),math.sin(pitch),math.cos(yaw)*math.cos(pitch)}
	camera.target=camera_pose.position+forward
	ecs.set_transform(world,camera_entity,camera_pose)
	ecs.set_camera_3d(world,camera_entity,camera)
}
