package main

import "core:fmt"
import rune "rune:core"
import b3 "vendor:box3d"
import rl "vendor:raylib"

BALL_COUNT  :: 18
FIXED_DELTA :: 1.0 / 60.0

physics_world: b3.WorldId
balls: [BALL_COUNT]b3.BodyId
accumulator: f32

camera := rl.Camera3D{
	position   = {10, 8, 12},
	target     = {0, 3, 0},
	up         = {0, 1, 0},
	fovy       = 45,
	projection = .PERSPECTIVE,
}

ball_colors := [6]rl.Color{
	rl.SKYBLUE,
	rl.ORANGE,
	rl.LIME,
	rl.PINK,
	rl.GOLD,
	rl.VIOLET,
}

create_box_shape :: proc(body: b3.BodyId, half_extents: b3.Vec3) {
	shape_def := b3.DefaultShapeDef()
	box := b3.MakeBoxHull(half_extents.x, half_extents.y, half_extents.z)
	_ = b3.CreateHullShape(body, shape_def, &box.base)
}

create_sphere_shape :: proc(body: b3.BodyId, radius: f32) {
	shape_def := b3.DefaultShapeDef()
	shape_def.density = 1
	shape_def.baseMaterial.friction = 0.35
	shape_def.baseMaterial.restitution = 0.65
	sphere := b3.Sphere{radius = radius}
	_ = b3.CreateSphereShape(body, shape_def, &sphere)
}

reset_simulation :: proc() {
	if !b3.IS_NULL(physics_world) {
		b3.DestroyWorld(physics_world)
	}

	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, -9.8, 0}
	physics_world = b3.CreateWorld(world_def)

	ground_def := b3.DefaultBodyDef()
	ground_def.position = {0, -0.5, 0}
	ground := b3.CreateBody(physics_world, ground_def)
	create_box_shape(ground, {6, 0.5, 6})

	for index in 0 ..< BALL_COUNT {
		column := index % 3
		row := index / 3
		radius := 0.38 + f32(index % 3) * 0.08

		body_def := b3.DefaultBodyDef()
		body_def.type = .dynamicBody
		body_def.position = {
			f32(column - 1) * 1.15,
			1.5 + f32(row) * 1.05,
			f32((row + column) % 3 - 1) * 0.55,
		}
		balls[index] = b3.CreateBody(physics_world, body_def)
		create_sphere_shape(balls[index], radius)
	}

	accumulator = 0
}

on_update :: proc(game: ^rune.Engine) {
	if rl.IsKeyPressed(.R) {
		reset_simulation()
	}

	accumulator += game.delta_time
	for accumulator >= FIXED_DELTA {
		b3.World_Step(physics_world, FIXED_DELTA, 4)
		accumulator -= FIXED_DELTA
	}
}

on_draw :: proc(game: ^rune.Engine) {
	rl.BeginMode3D(camera)
	rl.DrawPlane({0, 0, 0}, {12, 12}, rl.Color{55, 62, 72, 255})
	rl.DrawGrid(12, 1)

	for body, index in balls {
		position := b3.Body_GetPosition(body)
		radius := 0.38 + f32(index % 3) * 0.08
		draw_position := rl.Vector3{position.x, position.y, position.z}
		color := ball_colors[index % len(ball_colors)]
		rl.DrawSphere(draw_position, radius, color)
		rl.DrawSphereWires(draw_position, radius, 10, 10, rl.Fade(rl.BLACK, 0.3))
	}
	rl.EndMode3D()

	counters := b3.World_GetCounters(physics_world)
	rl.DrawText("Box3D ball drop", 24, 24, 28, rl.RAYWHITE)
	rl.DrawText("R: reset simulation", 24, 60, 18, rl.LIGHTGRAY)
	rl.DrawText(
		fmt.ctprintf("%d bodies  |  %d contacts", counters.bodyCount, counters.contactCount),
		24,
		88,
		18,
		rl.LIGHTGRAY,
	)
	rl.DrawFPS(24, 116)
}

main :: proc() {
	game, ok := rune.init("examples/box3d_balls/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/box3d_balls/project.json")
		return
	}

	reset_simulation()
	rune.run(&game, on_update, on_draw)

	if !b3.IS_NULL(physics_world) {
		b3.DestroyWorld(physics_world)
	}
}
