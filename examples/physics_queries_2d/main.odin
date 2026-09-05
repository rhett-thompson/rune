package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

player: ecs.Entity
collected: int
ray_end: [2]f32
ray_hit: bool
nearby: int
touching_wall: bool

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	player, _ = ecs.find_entity_by_id(world, "player")
	collected, nearby = 0, 0
	ray_end = {}
	ray_hit, touching_wall = false, false
}

control :: proc(game: ^rune.Engine, world: ^ecs.World) {
	body, found := ecs.get_rigid_body_2d(world, player)
	if !found {return}
	body.velocity = {input.axis(rune.input_state(game), "move_x") * 180, 0}
	ecs.set_rigid_body_2d(world, player, body)
}

after_physics :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for event in ecs.physics_2d_events(world) {
		if event.is_sensor {
			if event.kind == .Begin &&
			   event.b.entity == player &&
			   ecs.is_alive(world, event.a.entity) {
				// Removal is safe while iterating the copied event buffer.
				if ecs.destroy_entity(world, event.a.entity) {collected += 1}
			}
		} else if event.a.entity == player || event.b.entity == player {
			touching_wall = event.kind == .Begin
		}
	}
	transform, found := ecs.get_transform(world, player)
	if !found {return}
	origin := [2]f32{transform.position[0], transform.position[1]}
	filter := ecs.Default_Physics_Query_Filter
	filter.ignore = player
	filter.include_sensors = false
	hit, hit_found := ecs.physics_2d_raycast(world, origin, {240, 0}, filter)
	ray_hit = hit_found
	ray_end = hit.point if hit_found else origin + [2]f32{240, 0}
	filter.include_sensors = true
	nearby = len(ecs.physics_2d_overlap_circle(world, origin, 100, filter))
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	rl.ClearBackground({22, 26, 34, 255})
	rl.DrawText("PHYSICS QUERIES", 40, 32, 28, rl.RAYWHITE)
	rl.DrawText(
		"A / D to move. Gold sensors are pickups; blue walls are solid.",
		40,
		74,
		18,
		rl.LIGHTGRAY,
	)
	rl.DrawText(
		"The ray points right. The faint circle queries nearby colliders.",
		40,
		100,
		18,
		rl.LIGHTGRAY,
	)
	for entity, collider in world.box_colliders_2d {
		transform, found := ecs.get_transform(world, entity)
		if !found {continue}
		color := rl.GOLD if collider.is_sensor else rl.SKYBLUE
		if entity == player {color = rl.GREEN}
		rl.DrawRectangle(
			i32(transform.position[0] - collider.size[0] / 2),
			i32(transform.position[1] - collider.size[1] / 2),
			i32(collider.size[0]),
			i32(collider.size[1]),
			color,
		)
	}
	if transform, found := ecs.get_transform(world, player); found {
		x, y := transform.position[0], transform.position[1]
		rl.DrawCircleLines(i32(x), i32(y), 100, rl.DARKGRAY)
		rl.DrawLineEx({x, y}, {ray_end[0], ray_end[1]}, 2, rl.ORANGE if ray_hit else rl.LIGHTGRAY)
		if ray_hit {rl.DrawCircle(i32(ray_end[0]), i32(ray_end[1]), 5, rl.ORANGE)}
	}
	label := fmt.ctprintf(
		"Collected: %d / 3     Nearby colliders: %d     Wall contact: %t",
		collected,
		nearby,
		touching_wall,
	)
	rl.DrawText(label, 40, 430, 20, rl.RAYWHITE)
	rl.DrawText(
		"Console: pause, input move_right press, step 60, capture, reload",
		40,
		475,
		16,
		rl.GRAY,
	)
}

main :: proc() {
	game, ok := rune.init("examples/physics_queries_2d/project.json")
	if !ok {fmt.eprintln("Could not load physics queries project"); return}
	defer rune.shutdown(&game)
	if !rune.register_system(
		&game,
		{
			name = "pickups",
			start = start,
			fixed_update = control,
			post_physics = after_physics,
			draw = draw,
			on_scene_reloaded = start,
		},
	) {return}
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
