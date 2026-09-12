package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "rune:ecs"
import example_text "../shared/text"
import rl "vendor:raylib"

// Game-owned health and timer state, saved together so loading cannot bypass a
// death countdown or lose the protection remaining after a hit.
Health :: struct {
	current, maximum: i32,
	hit_protection, respawn_delay, respawn_protection: f32,
	protection_remaining, death_remaining: f32,
}
Default_Health :: Health{current=100,maximum=100,hit_protection=0.75,respawn_delay=1.25,respawn_protection=1.5}
Damage_Result :: enum {Ignored, Protected, Hurt, Killed}

health_valid :: proc(value:Health) -> bool {
	if value.maximum<=0 || value.current<0 || value.current>value.maximum {return false}
	for n in ([5]f32{value.hit_protection,value.respawn_delay,value.respawn_protection,value.protection_remaining,value.death_remaining}) {
		if n<0 || math.is_nan(n) || math.is_inf(n) {return false}
	}
	return true
}
actor_dead :: proc(world:^ecs.World,actor:ecs.Entity) -> bool {
	value,found:=ecs.get(world,actor,Health)
	return found && value.current<=0
}
apply_damage :: proc(world:^ecs.World,actor:ecs.Entity,amount:i32) -> Damage_Result {
	value,found:=ecs.get(world,actor,Health)
	if !found || !ecs.is_enabled(world,actor) || amount<=0 || !health_valid(value) || value.current==0 {return .Ignored}
	if value.protection_remaining>0 {return .Protected}
	value.current=max(0,value.current-amount)
	value.protection_remaining=value.hit_protection
	if value.current==0 {
		value.death_remaining=value.respawn_delay
		// Drop platform carry, movement, and buffered jumps at the moment of death.
		if pose,exists:=ecs.get_transform(world,actor); exists {ecs.character_controller_3d_teleport(world,actor,pose.position)}
	}
	if !ecs.set(world,actor,value) {return .Ignored}
	return .Killed if value.current==0 else .Hurt
}

// Called once per fixed tick before processing that tick's damage events.
// Returns true if a respawn invalidated the physics/trigger position snapshot.
update_course_health :: proc(world:^ecs.World,dt:f32) -> bool {
	if dt<=0 || math.is_nan(dt) || math.is_inf(dt) {return false}
	respawned:=false
	for actor in ecs.entities_with_component(world,"Health") {
		value,_:=ecs.get(world,actor,Health)
		if !health_valid(value) {continue}
		previous:=value
		value.protection_remaining=max(0,value.protection_remaining-dt)
		if value.current==0 {
			value.death_remaining=max(0,value.death_remaining-dt)
			if value.death_remaining==0 {
				spawn,found:=ecs.get(world,actor,Respawn_Point)
				if found && ecs.character_controller_3d_teleport(world,actor,spawn.position) {
					value.current=value.maximum
					value.protection_remaining=value.respawn_protection
					respawned=true
					interaction={};footsteps_moving=false;footstep_distance=0
					show_interaction_message("Respawned with full health. Inventory and door progress kept.")
				}
			}
		}
		if value!=previous {ecs.set(world,actor,value)}
	}
	return respawned
}

capture_health :: proc(world:^ecs.World,actor:ecs.Entity,a:mem.Allocator) -> (json.Value,bool) {
	value,found:=ecs.get(world,actor,Health)
	if !found || !health_valid(value) {return {},false}
	return ecs.runtime_json(value,a)
}
restore_health :: proc(world:^ecs.World,actor:ecs.Entity,data:json.Value) -> bool {
	if !ecs.json_shape_matches_type(data,Health) {return false}
	value:=Default_Health
	bytes,err:=json.marshal(data,allocator=context.temp_allocator)
	if err!=nil || json.unmarshal(bytes,&value,allocator=context.temp_allocator)!=nil || !health_valid(value) {return false}
	return ecs.set(world,actor,value)
}

draw_health_ui :: proc(world:^ecs.World) {
	value,found:=ecs.get(world,player,Health)
	if !found || !health_valid(value) {return}
	x:=rl.GetScreenWidth()-312
	rl.DrawRectangle(x,20,288,90,{18,25,36,225})
	color:=rl.Color{75,215,130,255}
	if value.current<=value.maximum/4 {color={245,80,80,255}}
	else if value.current<=value.maximum/2 {color={250,180,70,255}}
	example_text.draw(fmt.ctprintf("Health %d / %d",value.current,value.maximum),x+12,28,20,rl.RAYWHITE)
	rl.DrawRectangle(x+12,57,264,13,{65,72,86,255})
	rl.DrawRectangle(x+12,57,i32(264*f32(value.current)/f32(value.maximum)),13,color)
	if value.current==0 {
		example_text.draw(fmt.ctprintf("Respawning in %.1f s",value.death_remaining),x+12,79,16,{255,140,140,255})
	} else if value.protection_remaining>0 {
		example_text.draw("Protected",x+12,79,16,{255,225,130,255})
	} else {example_text.draw("Red zone: 25 damage per hit",x+12,79,16,rl.LIGHTGRAY)}
}
