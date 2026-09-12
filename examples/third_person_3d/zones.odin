package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import example_text "../shared/text"
import rl "vendor:raylib"

Zone_Kind :: enum {checkpoint, hazard}
Zone_Effect :: struct {kind:Zone_Kind, spawn_position:[3]f32, damage:i32}
Respawn_Point :: struct {position:[3]f32, checkpoint:ecs.Entity_Ref}
Default_Respawn_Point :: Respawn_Point{position={0,0,10}}

// Consume the engine's per-fixed-tick events. Checkpoints update the respawn
// position; hazards damage living actors while they remain inside the volume.
process_course_zones :: proc(world:^ecs.World) -> bool {
	for event in ecs.trigger_events_3d(world) {
		if event.kind!=.Enter || !ecs.is_enabled(world,event.trigger) || !ecs.is_enabled(world,event.other) {continue}
		zone,is_zone:=ecs.get(world,event.trigger,Zone_Effect)
		respawn,is_actor:=ecs.get(world,event.other,Respawn_Point)
		if !is_zone || !is_actor || zone.kind!=.checkpoint || actor_dead(world,event.other) {continue}
		id:=world.entity_ids[event.trigger]
		if respawn.checkpoint.id==id && respawn.position==zone.spawn_position {continue}
		respawn.position=zone.spawn_position;respawn.checkpoint.id=id
		ecs.set(world,event.other,respawn)
		show_interaction_message("Checkpoint activated. You will respawn here after death. F5 saves it.")
	}
	killed:=false
	for event in ecs.trigger_events_3d(world) {
		if event.kind==.Exit || !ecs.is_enabled(world,event.trigger) || !ecs.is_enabled(world,event.other) {continue}
		zone,is_zone:=ecs.get(world,event.trigger,Zone_Effect)
		if !is_zone || zone.kind!=.hazard {continue}
		switch apply_damage(world,event.other,zone.damage) {
		case .Hurt: show_interaction_message(fmt.tprintf("Hazard hit! Lost %d health. Step out of the red zone.",zone.damage),2)
		case .Killed:
			killed=true;interaction={};footsteps_moving=false;footstep_distance=0
			show_interaction_message("You died. Returning to your respawn point...")
		case .Ignored, .Protected:
		}
	}
	return killed
}
course_post_physics :: proc(game:^rune.Engine,world:^ecs.World) {
	if update_course_health(world,game.fixed_delta_time) {return}
	if !process_course_zones(world) && !actor_dead(world,player) {update_footsteps(game,world)}
}

draw_course_zones :: proc(world:^ecs.World) {
	entity,config,found:=ecs.active_camera_3d(world)
	pose,has_pose:=ecs.get_transform(world,entity)
	if !found || !has_pose {return}
	camera:=rl.Camera3D{position=transmute(rl.Vector3)pose.position,target=transmute(rl.Vector3)config.target,
		up=transmute(rl.Vector3)config.up,fovy=config.fovy,projection=.PERSPECTIVE}
	rl.BeginMode3D(camera)
	for zone in ecs.entities_with_component(world,"ZoneEffect") {
		value,has_trigger:=ecs.get(world,zone,ecs.Trigger3D)
		if !has_trigger || !value.enabled {continue}
		center,half_size,radius,valid:=ecs.trigger_geometry_3d(world,zone,value)
		if !valid {continue}
		effect,_:=ecs.get(world,zone,Zone_Effect)
		color:=rl.Color{70,230,155,255} if effect.kind==.checkpoint else rl.Color{250,80,75,255}
		if value.shape==.box {rl.DrawCubeWiresV(transmute(rl.Vector3)center,transmute(rl.Vector3)(half_size*2),color)}
		else {rl.DrawSphereWires(transmute(rl.Vector3)center,radius,8,16,color)}
	}
	rl.EndMode3D()
}
draw_zone_ui :: proc(world:^ecs.World) {
	respawn,_:=ecs.get(world,player,Respawn_Point)
	name:="green checkpoint" if respawn.checkpoint.id!="" else "start"
	example_text.draw(fmt.ctprintf("Green zone: checkpoint | Red sphere: hazard | Respawn: %s",name),24,246,17,{185,240,205,255})
}
