package main

import "core:math"

// Camera and avatar share the easing law, but keep independent orientation and
// angular speed so orbit input cannot turn the astronaut's body.
transport_frame :: proc(frame_up,frame_forward:^V3,frame_speed:^f32,up:V3,dt:f32,settings:=Default_Orientation_Smoothing) {
	current_up,current_forward,turn_speed:=frame_up^,frame_forward^,frame_speed^
	// Limit both speed and acceleration: exponential angle blending alone starts
	// a gravity reversal at its fastest speed. Small steps keep the easing stable
	// across render rates; a stalled frame must not jump the horizon forward.
	remaining:=clamp(dt,0,0.1)
	for remaining>0 {
		step:=min(remaining,1.0/120.0)
		remaining-=step
		cosine:=clamp(dot(current_up,up),-1,1)
		angle:=math.acos(cosine)
		if angle<0.0001 {turn_speed=0;break}
		axis:=cross(current_up,up)
		// Near opposite poles, tiny position changes must not choose an arbitrary
		// flip direction. Roll about the orbit heading until the arc is unambiguous.
		if cosine < -0.98 {axis=current_forward}
		axis=unit(axis)
		desired_speed:=min(settings.max_turn_speed,angle*settings.easing_rate)
		acceleration:=settings.angular_acceleration*step
		next_speed:=clamp(desired_speed,turn_speed-acceleration,turn_speed+acceleration)
		turn:=min(angle,(turn_speed+next_speed)*0.5*step)
		turn_speed=next_speed
		current_up=unit(current_up*math.cos(turn)+cross(axis,current_up)*math.sin(turn)+axis*dot(axis,current_up)*(1-math.cos(turn)))
		current_forward=unit(tangent(current_forward*math.cos(turn)+cross(axis,current_forward)*math.sin(turn)+axis*dot(axis,current_forward)*(1-math.cos(turn)),current_up))
	}
	frame_up^,frame_forward^,frame_speed^=current_up,current_forward,turn_speed
}

transport_camera :: proc(up:V3,dt:f32,settings:=Default_Orientation_Smoothing) {
	transport_frame(&camera_up,&camera_forward,&camera_turn_speed,up,dt,settings)
}

transport_avatar :: proc(up:V3,dt:f32,settings:=Default_Orientation_Smoothing) {
	transport_frame(&avatar_up,&avatar_forward,&avatar_turn_speed,up,dt,settings)
	if !avatar_moving {return}
	target:=tangent(facing,avatar_up)
	// A movement direction can momentarily point along visual up during a flip.
	// Keep the transported heading until it defines a usable tangent direction.
	if length(target)<0.05 {return}
	target=unit(target)
	angle:=math.atan2(dot(cross(avatar_forward,target),avatar_up),clamp(dot(avatar_forward,target),-1,1))
	step:=clamp(dt,0,0.1)
	limit:=settings.facing_turn_speed*step
	turn:=clamp(angle*(1-math.exp(-settings.facing_easing_rate*step)),-limit,limit)
	avatar_forward=unit(avatar_forward*math.cos(turn)+cross(avatar_up,avatar_forward)*math.sin(turn))
}
