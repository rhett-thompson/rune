package main

import example_text "../shared/text"

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import b3 "vendor:box3d"
import rl "vendor:raylib"

DEG_TO_RAD :: 0.017453292519943295

camera := rl.Camera3D {
	position   = {10, 8, 12},
	target     = {0, 3, 0},
	up         = {0, 1, 0},
	fovy       = 45,
	projection = .PERSPECTIVE,
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if rl.IsKeyPressed(.R) {
		_ = rune.change_scene(game, "scenes/main.scene.json")
	}
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	rl.BeginMode3D(camera)
	rl.DrawPlane({0, 0, 0}, {16, 12}, rl.Color{55, 62, 72, 255})
	draw_physics_boxes(world)
	draw_physics_spheres(world)
	rl.EndMode3D()

	counters, _ := ecs.physics_3d_counters(world)
	example_text.draw("Rolling balls", 24, 24, 28, rl.RAYWHITE)
	example_text.draw("R: reset", 24, 60, 18, rl.LIGHTGRAY)
	example_text.draw(
		fmt.ctprintf("%d bodies  |  %d contacts", counters.bodyCount, counters.contactCount),
		24,
		88,
		18,
		rl.LIGHTGRAY,
	)
}

draw_physics_boxes :: proc(world: ^ecs.World) {
	for entity in ecs.query(world, ecs.BoxCollider) {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_box_collider(world, entity)
		if !has_transform || !has_collider { continue }

		size := rl.Vector3 {
			collider.size[0] * transform.scale[0],
			collider.size[1] * transform.scale[1],
			collider.size[2] * transform.scale[2],
		}
		position := rl.Vector3{transform.position[0], transform.position[1], transform.position[2]}
		color := rl.Color{95, 105, 125, 255}
		if transform.rotation[2] != 0 {
			color = rl.Color{120, 105, 80, 255}
		}
		draw_oriented_box(position, size, transform.rotation, rl.Fade(color, 0.55), rl.Fade(rl.RAYWHITE, 0.45))
	}
}

draw_oriented_box :: proc(center, size: rl.Vector3, rotation_degrees: [3]f32, fill, wire: rl.Color) {
	half := vec3_scale(size, 0.5)
	corners := [8]rl.Vector3 {
		{-half.x, -half.y, -half.z},
		{half.x, -half.y, -half.z},
		{half.x, half.y, -half.z},
		{-half.x, half.y, -half.z},
		{-half.x, -half.y, half.z},
		{half.x, -half.y, half.z},
		{half.x, half.y, half.z},
		{-half.x, half.y, half.z},
	}
	for &corner in corners {
		corner = vec3_add(center, rotate_euler_degrees(corner, rotation_degrees))
	}

	draw_quad(corners[0], corners[1], corners[2], corners[3], fill)
	draw_quad(corners[5], corners[4], corners[7], corners[6], fill)
	draw_quad(corners[4], corners[0], corners[3], corners[7], fill)
	draw_quad(corners[1], corners[5], corners[6], corners[2], fill)
	draw_quad(corners[3], corners[2], corners[6], corners[7], fill)
	draw_quad(corners[4], corners[5], corners[1], corners[0], fill)

	draw_box_edge(corners[0], corners[1], wire)
	draw_box_edge(corners[1], corners[2], wire)
	draw_box_edge(corners[2], corners[3], wire)
	draw_box_edge(corners[3], corners[0], wire)
	draw_box_edge(corners[4], corners[5], wire)
	draw_box_edge(corners[5], corners[6], wire)
	draw_box_edge(corners[6], corners[7], wire)
	draw_box_edge(corners[7], corners[4], wire)
	draw_box_edge(corners[0], corners[4], wire)
	draw_box_edge(corners[1], corners[5], wire)
	draw_box_edge(corners[2], corners[6], wire)
	draw_box_edge(corners[3], corners[7], wire)
}

draw_quad :: proc(a, b, c, d: rl.Vector3, color: rl.Color) {
	rl.DrawTriangle3D(a, b, c, color)
	rl.DrawTriangle3D(a, c, d, color)
}

draw_box_edge :: proc(a, b: rl.Vector3, color: rl.Color) {
	rl.DrawLine3D(a, b, color)
}

rotate_euler_degrees :: proc(value: rl.Vector3, degrees: [3]f32) -> rl.Vector3 {
	result := value
	rx := f64(degrees[0] * DEG_TO_RAD)
	ry := f64(degrees[1] * DEG_TO_RAD)
	rz := f64(degrees[2] * DEG_TO_RAD)

	cx, sx := f32(math.cos(rx)), f32(math.sin(rx))
	cy, sy := f32(math.cos(ry)), f32(math.sin(ry))
	cz, sz := f32(math.cos(rz)), f32(math.sin(rz))

	result = {result.x, result.y * cx - result.z * sx, result.y * sx + result.z * cx}
	result = {result.x * cy + result.z * sy, result.y, -result.x * sy + result.z * cy}
	result = {result.x * cz - result.y * sz, result.x * sz + result.y * cz, result.z}
	return result
}

vec3_add :: proc(a, b: rl.Vector3) -> rl.Vector3 {
	return {a.x + b.x, a.y + b.y, a.z + b.z}
}

vec3_scale :: proc(value: rl.Vector3, scale: f32) -> rl.Vector3 {
	return {value.x * scale, value.y * scale, value.z * scale}
}

draw_physics_spheres :: proc(world: ^ecs.World) {
	for entity in ecs.query(world, ecs.SphereRenderer) {
		transform, has_transform := ecs.get_transform(world, entity)
		renderer, has_renderer := ecs.get_sphere_renderer(world, entity)
		if !has_transform || !has_renderer { continue }

		position := rl.Vector3{transform.position[0], transform.position[1], transform.position[2]}
		radius := renderer.radius * transform.scale[0]
		color := rl.Color{renderer.color.r, renderer.color.g, renderer.color.b, renderer.color.a}
		rl.DrawSphere(position, radius, color)
		rl.DrawSphereWires(position, radius, 10, 10, rl.Fade(rl.BLACK, 0.3))

		if native, found := ecs.physics_3d_native_body(world, entity); found {
			rotation := b3.Body_GetRotation(native)
			marker := b3.RotateVector(rotation, {radius, radius * 0.25, 0})
			marker_position := rl.Vector3 {
				transform.position[0] + marker.x,
				transform.position[1] + marker.y,
				transform.position[2] + marker.z,
			}
			rl.DrawLine3D(position, marker_position, rl.BLACK)
			rl.DrawSphere(marker_position, radius * 0.11, rl.BLACK)
		}
	}
}

main :: proc() {
	game, ok := rune.init("examples/box3d_balls/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/box3d_balls/project.json")
		return
	}

	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }

	if !rune.register_system(&game, {name = "box3d_balls", update = on_update, draw = on_draw}) {
		fmt.eprintln("Could not register Box3D system")
		return
	}
	if !rune.run(&game) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
	}
}
