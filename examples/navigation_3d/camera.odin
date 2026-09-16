package main

import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

orbit:ecs.OrbitCamera3D

default_course_camera :: proc() -> ecs.OrbitCamera3D {
	result:=ecs.default_orbit_camera_3d()
	result.target={1,0,0}
	result.distance=math.sqrt(f32(1185))
	result.yaw=math.atan2(f32(23),f32(16))*180/math.PI
	result.pitch=math.asin(20/result.distance)*180/math.PI
	result.min_pitch=5;result.max_pitch=85
	result.min_distance=4;result.max_distance=80
	result.pan_action="pan_camera"
	result.pan_x_axis="orbit_x"
	result.pan_y_axis="orbit_y"
	return result
}

update_course_camera :: proc(game:^rune.Engine,world:^ecs.World) {
	controls:=rune.input_state(game)
	if input.frame_action(controls,"reset_camera").pressed {orbit=default_course_camera()}
	if input.frame_action(controls,"focus_agent").pressed {
		if agent,found:=ecs.find_entity_by_id(world,"agent");found {
			if pose,ok:=ecs.get_transform(world,agent);ok {orbit.target=pose.position+[3]f32{0,0.9,0}}
		}
	}
	// Scale zoom and screen-plane panning with the view distance. Neither uses
	// simulation dt, so orbit controls remain responsive while the game is paused.
	orbit.zoom_sensitivity=orbit.distance*0.1
	// Preserve pointer tracking across viewport sizes and field-of-view changes.
	orbit.pan_sensitivity=2*math.tan(camera.fovy*math.PI/360)/f32(max(rl.GetScreenHeight(),1))
	pose:=ecs.update_orbit_camera_3d(&orbit,controls,game.frame_delta_time)
	camera.position=pose.position;camera.target=orbit.target
}
