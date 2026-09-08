package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

player: ecs.Entity
sensor_entries: int
ray_hit: bool
ray_end: [2]f32

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	player, _ = ecs.find_entity_by_id(world, "player")
	sensor_entries = 0
	ray_hit = false
	ray_end = {}
}

control :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !ecs.is_enabled(world, player) {return}
	body, found := ecs.get_rigid_body_2d(world, player)
	if !found {return}
	body.velocity[0] = input.axis(rune.input_state(game), "move_x") * 200
	if input.pressed(rune.input_state(game), "jump") && body.grounded {
		body.velocity[1] = -500
		body.grounded = false
	}
	ecs.set_rigid_body_2d(world, player, body)
}

after_physics :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for event in ecs.physics_2d_events(world) {
		if event.is_sensor && event.kind == .Begin && event.b.entity == player {sensor_entries += 1}
	}
	pose, found := ecs.get_transform(world, player)
	collider, has_collider := ecs.get_capsule_collider_2d(world, player)
	if !found || !has_collider {return}
	origin := ecs.collider_center_2d(pose, collider.offset)
	filter := ecs.Default_Physics_Query_Filter
	filter.ignore = player
	filter.include_sensors = false
	hit, found_hit := ecs.physics_2d_raycast(world, origin, {220,0}, filter)
	ray_hit = found_hit
	ray_end = hit.point if found_hit else origin + [2]f32{220,0}
}

draw_ui :: proc(game: ^rune.Engine, world: ^ecs.World) {
	rl.DrawText("COLLIDER OFFSETS + CAPSULES", 32, 24, 26, rl.RAYWHITE)
	rl.DrawText("A / D: move   SPACE: jump   Backtick: console", 32, 63, 18, rl.LIGHTGRAY)
	rl.DrawText("Green: collision outlines   White crosses: entity origins", 32, 92, 18, rl.LIGHTGRAY)
	rl.DrawText("Player origin is at its feet. Collider offset is [0, -32].", 32, 121, 18, rl.LIGHTGRAY)
	for entity in ecs.query(world, ecs.Transform) {
		if !ecs.has_component_data(world,entity,"BoxCollider2D") &&
		   !ecs.has_component_data(world,entity,"CircleCollider2D") &&
		   !ecs.has_component_data(world,entity,"CapsuleCollider2D") {continue}
		pose, _ := ecs.get_transform(world,entity)
		x,y := i32(pose.position[0]), i32(pose.position[1])
		rl.DrawLine(x-5,y,x+5,y,rl.WHITE)
		rl.DrawLine(x,y-5,x,y+5,rl.WHITE)
	}
	pose, found := ecs.get_transform(world,player)
	collider, has_collider := ecs.get_capsule_collider_2d(world,player)
	if found && has_collider && ecs.is_enabled(world,player) {
		origin := ecs.collider_center_2d(pose,collider.offset)
		rl.DrawLineEx({origin[0],origin[1]}, {ray_end[0],ray_end[1]}, 2, rl.ORANGE if ray_hit else rl.GRAY)
	}
	label := fmt.ctprintf("Gold capsule is a sensor. Entries: %d",sensor_entries)
	rl.DrawText(label,32,544,18,rl.GOLD)
	rl.DrawText("Try: set player CapsuleCollider2D.offset [20,-32]",32,573,17,rl.LIGHTGRAY)
}

main :: proc() {
	game, ok := rune.init("examples/colliders_2d/project.json")
	if !ok {return}
	defer rune.shutdown(&game)
	assert(rune.register_system(&game,{name="capsule_playground",start=start,on_scene_reloaded=start,fixed_update=control,post_physics=after_physics,draw_ui=draw_ui}))
	rune.run_project(&game)
}
