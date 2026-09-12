package main

import "core:math"
import "rune:ecs"

Door_Closed_Y :: f32(1.25)
Door_Open_Y :: f32(4)
Door_Travel_Time :: f32(0.8)

Door_Animation :: struct {
	entity: ecs.Entity,
	from_y, to_y, last_y, elapsed, duration: f32,
}
door_animation: Door_Animation

doorway_blocked :: proc(world:^ecs.World,door:ecs.Entity) -> bool {
	// Motors are separate from ordinary collider queries. Check the whole
	// doorway every closing step, including characters entering during travel.
	for actor in ecs.entities_with_component(world,"CharacterController3D") {
		feet,_:=ecs.get_transform(world,actor)
		motor,_:=ecs.get_character_controller_3d(world,actor)
		if math.abs(feet.position.x)<1+motor.radius && math.abs(feet.position.z-6.5)<0.18+motor.radius &&
		   feet.position.y<2.5 && feet.position.y+motor.height>0 {return true}
	}
	return len(ecs.physics_3d_overlap_box(world,{0,1.25,6.5},{0.99,1.24,0.17},
		{layers=~u64(0),ignore=door,include_sensors=false}))>0
}

course_door_prompt :: proc(world:^ecs.World,door:ecs.Entity) -> string {
	state,found:=ecs.get(world,door,Door_State)
	if !found {return "Door unavailable"}
	actor,_:=ecs.find_entity_by_id(world,"player")
	if !state.unlocked && state.required_key!="" {
		if inventory_count(world,actor,state.required_key)==0 {return "Requires a brass key"}
		return "Unlock door"
	}
	return "Close door" if state.open else "Open door"
}
refresh_course_door_prompt :: proc(world:^ecs.World) {
	door,found:=ecs.find_entity_by_id(world,"interaction_door")
	value,has_value:=ecs.get(world,door,ecs.Interactable3D)
	if found && has_value {
		value.prompt=course_door_prompt(world,door)
		ecs.set(world,door,value)
	}
}

toggle_course_door :: proc(world:^ecs.World,door:ecs.Entity,actor:ecs.Entity) -> string {
	state,found:=ecs.get(world,door,Door_State)
	if !found {return "Door unavailable."}
	if !state.unlocked && state.required_key!="" && inventory_count(world,actor,state.required_key)==0 {
		return "Requires a brass key. Find it beside the guide."
	}
	opening:=!state.open
	if !opening && doorway_blocked(world,door) {return "The doorway is blocked."}
	state.unlocked=true;state.open=opening
	ecs.set(world,door,state)
	refresh_course_door_prompt(world)
	return "Door opening." if opening else "Door closing."
}

update_course_door :: proc(world:^ecs.World,dt:f32) {
	if dt<=0 || math.is_nan(dt) || math.is_inf(dt) {return}
	door,found:=ecs.find_entity_by_id(world,"interaction_door")
	pose,has_pose:=ecs.get_transform(world,door)
	value,has_action:=ecs.get(world,door,ecs.Interactable3D)
	state,has_state:=ecs.get(world,door,Door_State)
	if !found || !has_pose || !has_action || !has_state || !ecs.is_enabled(world,door) {door_animation={};return}
	target_y:=Door_Open_Y if state.open && state.unlocked else Door_Closed_Y
	if pose.position.y==target_y {return}
	if target_y==Door_Closed_Y && doorway_blocked(world,door) {
		target_y=Door_Open_Y
		state.open=true;state.unlocked=true;ecs.set(world,door,state)
		show_interaction_message("Doorway blocked. Reopening.")
	}
	if door_animation.entity!=door || door_animation.to_y!=target_y || door_animation.last_y!=pose.position.y {
		door_animation={entity=door,from_y=pose.position.y,to_y=target_y,last_y=pose.position.y,
			duration=max(0.01,Door_Travel_Time*math.abs(target_y-pose.position.y)/(Door_Open_Y-Door_Closed_Y))}
	}
	door_animation.elapsed=min(door_animation.elapsed+dt,door_animation.duration)
	t:=door_animation.elapsed/door_animation.duration
	// Smoothstep gives a gentle start and stop, with exact endpoint positions.
	pose.position.y=door_animation.from_y+(target_y-door_animation.from_y)*(t*t*(3-2*t))
	if t>=1 {
		pose.position.y=target_y
		show_interaction_message("Door opened." if target_y==Door_Open_Y else "Door closed.",2)
	}
	door_animation.last_y=pose.position.y
	ecs.set_transform(world,door,pose)
	// Keep the interaction point at hand height while the panel moves overhead.
	value.offset.y=Door_Closed_Y-pose.position.y
	value.prompt=course_door_prompt(world,door)
	ecs.set(world,door,value)
}
