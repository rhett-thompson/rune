package main

import "core:math"
import rune "rune:core"
import "rune:ecs"

footstep_distance: f32
footsteps_moving: bool

update_footsteps :: proc(game: ^rune.Engine, world: ^ecs.World) {
	motor, found := ecs.get_character_controller_3d_state(world, player)
	feet, has_pose := ecs.get_transform(world, player)
	settings, configured := ecs.get(world, player, Third_Person_Settings)
	if !found || !has_pose || !configured || !motor.active || !motor.grounded ||
	   settings.footstep_stride <= 0 || (motor.move[0] == 0 && motor.move[1] == 0) {
		footstep_distance = 0
		footsteps_moving = false
		return
	}
	// Measure resolved ground travel, excluding passive platform carry.
	motion := feet.position-motor.previous_position-motor.support_velocity*game.fixed_delta_time
	distance := math.sqrt(motion[0]*motion[0]+motion[2]*motion[2])
	// Ignore contact-settling motion so touching a wall cannot trigger a start.
	if distance < max(0.0001, game.fixed_delta_time*0.1) {
		footstep_distance = 0
		footsteps_moving = false
		return
	}
	if !footsteps_moving {
		footsteps_moving = true
		footstep_distance = 0
		rune.play_audio(game, world, player, "footsteps")
		return
	}
	stride := max(settings.footstep_stride, 0.1)
	footstep_distance += distance
	if footstep_distance >= stride {
		footstep_distance = math.mod(footstep_distance, stride)
		rune.play_audio(game, world, player, "footsteps")
	}
}
