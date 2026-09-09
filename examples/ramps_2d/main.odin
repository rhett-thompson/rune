package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

player: ecs.Entity
sensor_entries: int
facing: f32 = 1

after_load :: proc(game: ^rune.Engine, world: ^ecs.World) {
	player, _ = ecs.find_entity_by_id(world,"player")
	sensor_entries = 0
	facing = 1
}

control :: proc(game: ^rune.Engine, world: ^ecs.World) {
	move_platforms(world,game.fixed_delta_time)
	ecs.character_controller_2d_crouch(world,player,input.is_down(rune.input_state(game),"move_down"))
	axis := input.axis(rune.input_state(game),"move_x")
	if axis != 0 {facing = 1 if axis > 0 else -1}
	ecs.character_controller_2d_move(world,player,axis)
	if input.pressed(rune.input_state(game),"dash") {ecs.character_controller_2d_dash(world,player,facing)}
	if input.pressed(rune.input_state(game),"jump") {
		if input.is_down(rune.input_state(game),"move_down") {ecs.character_controller_2d_drop_through(world,player)}
		else {ecs.character_controller_2d_jump(world,player)}
	}
	if input.released(rune.input_state(game),"jump") {ecs.character_controller_2d_release_jump(world,player)}
}

after_physics :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for event in ecs.physics_2d_events(world) {
		if event.is_sensor && event.kind==.Begin && event.b.entity==player {sensor_entries+=1}
	}
}

// This example's camera is identity. Terrain visuals read the same JSON points
// as physics; a game's art can instead be sprites or meshes over its colliders.
draw_terrain :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for e in ecs.query(world,PlatformMotion) {
		motion,_ := ecs.get(world,e,PlatformMotion)
		pose,found := ecs.get_transform(world,e)
		if !found || motion.axis<0 || motion.axis>1 {continue}
		a := [2]f32{pose.position[0],pose.position[1]+8}
		b := a
		a[motion.axis],b[motion.axis] = motion.minimum,motion.maximum
		rl.DrawLineV({a[0],a[1]},{b[0],b[1]},{50,60,75,255})
	}
	for e in ecs.query(world,ecs.PolygonCollider2D) {
		pose,found := ecs.get_transform(world,e)
		shape,_ := ecs.get_polygon_collider_2d(world,e)
		if !found {continue}
		color := rl.Color{64,82,108,255}
		if shape.is_sensor {color = {180,130,35,110}}
		a := ecs.collider_point_2d(pose,shape.vertices[0],shape.offset)
		for i in 1..<len(shape.vertices)-1 {
			b := ecs.collider_point_2d(pose,shape.vertices[i],shape.offset)
			c := ecs.collider_point_2d(pose,shape.vertices[i+1],shape.offset)
			if (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]) > 0 {b,c=c,b}
			rl.DrawTriangle({a[0],a[1]},{b[0],b[1]},{c[0],c[1]},color)
		}
	}
	for e in ecs.query(world,ecs.SegmentCollider2D) {
		pose,found := ecs.get_transform(world,e)
		shape,_ := ecs.get_segment_collider_2d(world,e)
		if !found {continue}
		a := ecs.collider_point_2d(pose,shape.start,shape.offset)
		b := ecs.collider_point_2d(pose,shape.end,shape.offset)
		rl.DrawLineEx({a[0],a[1]},{b[0],b[1]},5,{80,115,115,255})
	}
 // Visuals read the live capsule, including crouch and scale. Drawing never
 // changes simulation state or the authored collider.
 if capsule,found := ecs.get_effective_capsule_collider_2d(world,player); found {
  pose,_ := ecs.get_transform(world,player)
  a,b,radius := ecs.capsule_collider_2d_geometry(capsule,pose)
  color := rl.Color{70,155,245,255}
  state,_ := ecs.get_character_controller_2d_state(world,player)
  if state.dashing {color = {70,230,220,255}}
  rl.DrawLineEx({a[0],a[1]},{b[0],b[1]},2*radius,color)
  rl.DrawCircleV({a[0],a[1]},radius,color)
  rl.DrawCircleV({b[0],b[1]},radius,color)
 }
}

draw_ui :: proc(game: ^rune.Engine, world: ^ecs.World) {
	rl.DrawText("RAMPS + CHAINED DASHES",32,24,26,rl.RAYWHITE)
	rl.DrawText("A/D: move   SPACE: jump   SHIFT: dash   S/DOWN: crouch   S + SPACE: drop",32,65,18,rl.LIGHTGRAY)
	rl.DrawText("Tap SPACE for a short hop; hold it to reach the orange ledge.",32,96,18,rl.LIGHTGRAY)
	rl.DrawText("Tap SHIFT again during a dash to chain; steer to redirect. Up to 3 before cooldown.",32,127,18,rl.LIGHTGRAY)
	rl.DrawText("Walk right into the shaft. Jump between walls to climb; press toward a wall to slide.",32,158,16,rl.LIGHTGRAY)
	rl.DrawText("WALL SHAFT",1050,195,16,rl.LIGHTGRAY)
	rl.DrawText("ENTER BELOW",1030,515,16,rl.LIGHTGRAY)
	rl.DrawText("ONE-WAY SHUTTLE",340,245,16,rl.LIGHTGRAY)
	rl.DrawText("ELEVATOR",50,515,16,rl.LIGHTGRAY)
	rl.DrawText("LOW TUNNEL",704,515,16,rl.LIGHTGRAY)
	rl.DrawText("ONE-WAY",782,237,16,rl.ORANGE)
	rl.DrawText("CROUCH STEP",520,268,16,rl.LIGHTGRAY)
	rl.DrawText("CONVEX POLYGON",320,466,16,rl.LIGHTGRAY)
	rl.DrawText("SEGMENT BRIDGE",662,408,16,rl.LIGHTGRAY)
	state,_ := ecs.get_character_controller_2d_state(world,player)
	support,_ := ecs.entity_id(world,state.support_entity)
	if !state.grounded {support = "air"}
	rl.DrawText(fmt.ctprintf("Support: %s    Carry: %.0f, %.0f    Sensor entries: %d",support,state.support_velocity[0],state.support_velocity[1],sensor_entries),32,537,18,rl.GOLD)
	stance := "standing"
 if state.crouched {stance = "crouching"}
 if state.stand_blocked {stance = "ceiling blocks standing"}
 if state.wall_sliding {stance = "wall sliding"}
 if state.wall_jump_lock_remaining > 0 {stance = "wall jump"}
 if state.dashing {stance = "dashing"}
 config,_ := ecs.get_character_controller_2d(world,player)
 rl.DrawText(fmt.ctprintf("Dash %d/%d  |  queued: %t  |  cooldown: %.2f",state.dash_chain_index,config.dash_chain_count,state.dash_queued,state.dash_cooldown_remaining),740,537,16,rl.SKYBLUE)
 rl.DrawText(fmt.ctprintf("%s   |   Backtick: console   |   Try: set player CharacterController2D.dash_chain_count 5",stance),32,570,15,rl.LIGHTGRAY)
	pose,found := ecs.get_transform(world,player)
	if found {
		filter := ecs.Default_Physics_Query_Filter
		filter.ignore,filter.include_sensors=player,false
		origin := [2]f32{pose.position[0],pose.position[1]-32}
		hit,ok := ecs.physics_2d_raycast(world,origin,{0,120},filter)
		if ok {
			rl.DrawLineEx({origin[0],origin[1]},{hit.point[0],hit.point[1]},2,rl.ORANGE)
			rl.DrawCircleV({hit.point[0],hit.point[1]},3,rl.ORANGE)
		}
	}
}

main :: proc() {
	game,ok := rune.init("examples/ramps_2d/project.json")
	if !ok {return}
	defer rune.shutdown(&game)
	assert(ecs.register_component(rune.component_registry(&game),"PlatformMotion",PlatformMotion,PlatformMotion{},"Example-only platform path and speed; Odin supplies kinematic velocity."))
	assert(rune.register_system(&game,{name="ramps",start=after_load,on_scene_reloaded=after_load,fixed_update=control,post_physics=after_physics,pre_draw=draw_terrain,draw_ui=draw_ui}))
	rune.run_project(&game)
}
