package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:input"
import example_text "../shared/text"
import rl "vendor:raylib"

interaction: ecs.Interaction_State_3D
interaction_message: string
interaction_message_time: f32

reset_interactions :: proc() {
	interaction={};interaction_message="";interaction_message_time=0
	door_animation={}
}

suspend_interactions :: proc(game:^rune.Engine) {
	// Consume held input during pause/console/focus loss, preventing an
	// unfinished hold or a console keypress from activating on resume.
	interaction={actor=player,was_down=input.is_down(rune.input_state(game),"interact")}
}

update_gameplay :: proc(game:^rune.Engine,world:^ecs.World) {
	update_camera(game,world)
	interaction_message_time=max(0,interaction_message_time-game.delta_time)
	if rune.is_paused(game) || console.is_open(rune.developer_console(game)) || !rl.IsWindowFocused() {
		suspend_interactions(game);return
	}
	feet,found:=ecs.get_transform(world,player)
	if !found {reset_interactions();return}
	motor,_:=ecs.get_character_controller_3d_state(world,player)
	config,_:=ecs.get_character_controller_3d(world,player)
	height:=config.height
	if motor.active {height=motor.height}
	yaw:=facing_yaw*f32(math.PI/180)
	target:=ecs.update_interaction_3d(world,&interaction,player,feet.position+[3]f32{0,height*0.65,0},
		{math.sin(yaw),0,math.cos(yaw)},input.is_down(rune.input_state(game),"interact"),game.delta_time)
	if target!=0 {
		interaction_message=activate_course_interaction(world,target)
		interaction_message_time=5
	}
}

// Game-specific effects; the engine only returns the activated entity.
activate_course_interaction :: proc(world:^ecs.World,target:ecs.Entity) -> string {
	switch world.entity_ids[target] {
	case "interaction_pickup":
		ecs.set_enabled(world,target,false)
		return "Collected the golden cube."
	case "interaction_guide":
		return "Guide: Try the door, then collect the golden cube. Hold E to talk again."
	case "interaction_door":
		return toggle_course_door(world,target)
	}
	return ""
}

draw_interaction_ui :: proc(world:^ecs.World) {
	y:=rl.GetScreenHeight()-105
	rl.DrawRectangle(16,y-12,rl.GetScreenWidth()-32,100,{19,26,38,225})
	text:=cstring("Face a nearby object | E use / collect | Hold E to talk to the guide")
	if value,found:=ecs.get(world,interaction.focus.entity,ecs.Interactable3D); found && value.enabled && ecs.is_enabled(world,interaction.focus.entity) {
		camera_entity,camera,has_camera:=ecs.active_camera_3d(world)
		camera_pose,has_pose:=ecs.get_transform(world,camera_entity)
		if has_camera && has_pose {
			view:=rl.Camera3D{position=transmute(rl.Vector3)camera_pose.position,target=transmute(rl.Vector3)camera.target,
				up=transmute(rl.Vector3)camera.up,fovy=camera.fovy,projection=.PERSPECTIVE}
			point:=rl.GetWorldToScreen(transmute(rl.Vector3)interaction.focus.point,view)
			delta:=interaction.focus.point-camera_pose.position
			forward:=camera.target-camera_pose.position
			if delta.x*forward.x+delta.y*forward.y+delta.z*forward.z>0 &&
			   point.x>=0 && point.x<f32(rl.GetScreenWidth()) && point.y>=0 && point.y<f32(y-12) {
				rl.DrawCircleLines(i32(point.x),i32(point.y),9,{255,225,125,255})
				rl.DrawCircle(i32(point.x),i32(point.y),3,{255,225,125,255})
			}
		}
		verb:="Hold E" if value.hold_seconds>0 else "E"
		text=fmt.ctprintf("%s  -  %s",verb,value.prompt)
		if value.hold_seconds>0 {
			rl.DrawRectangle(24,y+30,250,5,{75,88,104,255})
			rl.DrawRectangle(24,y+30,i32(250*interaction.progress),5,{90,220,185,255})
		}
	}
	example_text.draw(text,24,y,20,rl.RAYWHITE)
	if interaction_message_time>0 {example_text.draw(fmt.ctprintf("%s",interaction_message),24,y+48,18,{245,220,145,255})}
}
