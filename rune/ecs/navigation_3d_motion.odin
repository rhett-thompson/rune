package ecs

import "core:math"
import "rune:navigation"

Navigation_Stopped_Speed_3D :: f32(0.05)

navigation_travel_distance_3d :: proc(delta:[3]f32,controller:bool) -> f32 {
	if controller {return math.sqrt(delta.x*delta.x+delta.z*delta.z)}
	return navigation.length_3d(delta)
}

navigation_goal_reached_3d :: proc(config:NavAgent3D,position,goal:[3]f32) -> bool {
	delta:=goal-position
	tolerance:=config.stopping_distance+config.arrival_distance
	if config.drive_controller {
		return navigation_travel_distance_3d(delta,true)<=tolerance && abs(delta.y)<=max(tolerance,0.25)
	}
	return navigation.length_3d(delta)<=tolerance
}

navigation_remaining_distance_3d :: proc(points:[][3]f32,next:int,position:[3]f32,controller:bool) -> f32 {
	if next>=len(points) {return 0}
	distance:=navigation_travel_distance_3d(points[next]-position,controller)
	for i in next+1..<len(points) {distance+=navigation_travel_distance_3d(points[i]-points[i-1],controller)}
	return distance
}

// Surface crossings on a straight XZ leg are bookkeeping, not steering goals.
// The motor follows the physical ramp height while aiming at the next real bend.
navigation_straight_leg_end_3d :: proc(points:[][3]f32,next:int) -> int {
	end:=next
	direction:[3]f32
	for i:=next;i>0;i-=1 {
		direction=points[i]-points[i-1];direction.y=0
		length:=navigation.length_3d(direction)
		if length>1e-5 {direction/=length;break}
	}
	for i in next+1..<len(points) {
		segment:=points[i]-points[i-1];segment.y=0
		length:=navigation.length_3d(segment)
		if length>1e-5 {
			segment/=length
			if navigation.length_3d(direction)>1e-5 && navigation.dot_3d(direction,segment)<0.999 {break}
			direction=segment
		}
		end=i
	}
	return end
}

navigation_controller_passed_point_3d :: proc(points:[][3]f32,index:int,position:[3]f32,config:NavAgent3D) -> bool {
	// Only skip passed crossings inside a straight leg. Real corners still
	// require proximity, and the lateral/height guards keep separate floors apart.
	if index<=0 || navigation_straight_leg_end_3d(points,index)==index {return false}
	previous:=index-1
	for previous>0 && navigation_travel_distance_3d(points[index]-points[previous],true)<=1e-5 {previous-=1}
	segment:=points[index]-points[previous]
	delta:=position-points[previous]
	length_squared:=segment.x*segment.x+segment.z*segment.z
	if length_squared<=1e-10 {return false}
	progress:=(delta.x*segment.x+delta.z*segment.z)/length_squared
	if progress<1 {return false}
	expected:=points[previous]+segment*progress
	return navigation_travel_distance_3d(position-expected,true)<=max(config.radius,config.waypoint_distance)+1e-4 &&
		abs(position.y-expected.y)<=max(config.waypoint_distance,0.25)
}

// Account for the next fixed step as well as the braking distance. A continuous
// sqrt(2*a*d) bound alone starts braking too late in a discrete motor.
navigation_braking_speed_3d :: proc(distance,terminal_speed,braking,dt:f32) -> f32 {
	if braking<=0 {return 3.402823e38}
	step:=f64(braking)*f64(dt)
	return f32(max(f64(0),math.sqrt(step*step+f64(terminal_speed)*f64(terminal_speed)+2*f64(braking)*f64(max(distance,0)))-step))
}

navigation_speed_limit_3d :: proc(config:NavAgent3D,points:[][3]f32,next:int,position:[3]f32,braking,dt:f32) -> f32 {
	limit:=config.speed
	if config.auto_braking {
		remaining:=navigation_remaining_distance_3d(points,next,position,config.drive_controller)
		limit=min(limit,navigation_braking_speed_3d(max(0,remaining-config.stopping_distance),0,braking,dt))
	}
	if config.corner_slowdown && braking>0 {
		previous:=position
		incoming:[3]f32
		distance:f32
		for i in next..<len(points) {
			segment:=points[i]-previous
			previous=points[i]
			distance+=navigation_travel_distance_3d(segment,config.drive_controller)
			segment.y=0
			length:=navigation.length_3d(segment)
			if length<=1e-5 {continue}
			// Use the authored route tangent. Recovery from contact drift toward
			// a nearby crossing must not manufacture a sharp corner there.
			incoming=segment/length
			for k:=i;k>0;k-=1 {
				path_segment:=points[i]-points[k-1];path_segment.y=0
				path_length:=navigation.length_3d(path_segment)
				if path_length>1e-5 {incoming=path_segment/path_length;break}
			}
			outgoing:[3]f32
			for j in i+1..<len(points) {
				outgoing=points[j]-points[i];outgoing.y=0
				out_length:=navigation.length_3d(outgoing)
				if out_length>1e-5 {outgoing/=out_length;break}
			}
			if navigation.length_3d(outgoing)<=1e-5 {break}
			cosine:=math.clamp(navigation.dot_3d(incoming,outgoing),-1,1)
			if cosine>=0.999 {continue}
			// Right-angle and sharper bends approach a stop. Gentle bends retain
			// a proportion of cruise speed. Coplanar portal crossings do not brake.
			corner_speed:=config.speed*max(cosine,0)
			corner_distance:=max(0,distance-config.waypoint_distance) if config.drive_controller else distance
			limit=min(limit,navigation_braking_speed_3d(corner_distance,corner_speed,braking,dt))
		}
	}
	return limit
}

navigation_approach_speed_3d :: proc(current,target,acceleration,braking,dt:f32) -> f32 {
	rate:=acceleration if target>current else braking
	if rate<=0 {return target}
	return current+math.clamp(target-current,-rate*dt,rate*dt)
}

navigation_rotate_3d :: proc(transform:^Transform,velocity:[3]f32,config:NavAgent3D,dt:f32) {
	if !config.update_rotation || config.angular_speed<=0 || navigation_travel_distance_3d(velocity,true)<=Navigation_Stopped_Speed_3D {return}
	angle:=math.atan2(velocity.x,velocity.z)*180/math.PI
	delta:=math.mod(angle-transform.rotation.y+180,360)
	if delta<0 {delta+=360}
	delta-=180
	transform.rotation.y+=math.clamp(delta,-config.angular_speed*dt,config.angular_speed*dt)
}
