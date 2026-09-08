package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

player: ecs.Entity
sensor_entries: int

after_load :: proc(game: ^rune.Engine, world: ^ecs.World) {
	player, _ = ecs.find_entity_by_id(world,"player")
	sensor_entries = 0
}

control :: proc(game: ^rune.Engine, world: ^ecs.World) {
	move_platforms(world,game.fixed_delta_time)
	ecs.character_controller_2d_move(world,player,input.axis(rune.input_state(game),"move_x"))
	if input.pressed(rune.input_state(game),"jump") {
		if input.is_down(rune.input_state(game),"move_down") {ecs.character_controller_2d_drop_through(world,player)}
		else {ecs.character_controller_2d_jump(world,player)}
	}
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
}

draw_ui :: proc(game: ^rune.Engine, world: ^ecs.World) {
	rl.DrawText("RAMPS + ONE-WAY PLATFORMS",32,24,26,rl.RAYWHITE)
	rl.DrawText("A / D: move   SPACE: jump   S / DOWN + SPACE: drop   Backtick: console",32,65,18,rl.LIGHTGRAY)
	rl.DrawText("Ride the teal elevator. Jump through the violet shuttle or orange ledge.",32,96,18,rl.LIGHTGRAY)
	rl.DrawText("Violet / orange: one-way. Teal / green: solid. Gold diamond: sensor.",32,127,18,rl.LIGHTGRAY)
	rl.DrawText("45 degree slope limit   8 unit ground snap   100 ms coyote / jump buffer",32,158,17,rl.LIGHTGRAY)
	rl.DrawText("ONE-WAY SHUTTLE",340,245,16,rl.LIGHTGRAY)
	rl.DrawText("ELEVATOR",50,515,16,rl.LIGHTGRAY)
	rl.DrawText("ONE-WAY",582,237,16,rl.ORANGE)
	rl.DrawText("CONVEX POLYGON",320,466,16,rl.LIGHTGRAY)
	rl.DrawText("SEGMENT BRIDGE",662,408,16,rl.LIGHTGRAY)
	state,_ := ecs.get_character_controller_2d_state(world,player)
	support,_ := ecs.entity_id(world,state.support_entity)
	if !state.grounded {support = "air"}
	rl.DrawText(fmt.ctprintf("Support: %s    Carry: %.0f, %.0f    Sensor entries: %d",support,state.support_velocity[0],state.support_velocity[1],sensor_entries),32,537,18,rl.GOLD)
	rl.DrawText("Try: set shuttle PlatformMotion.speed 120",32,570,17,rl.LIGHTGRAY)
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
