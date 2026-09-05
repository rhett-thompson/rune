package gizmos

import "core:math"
import "rune:ecs"
import rl "vendor:raylib"

Settings :: struct {
	enabled:        bool,
	transforms:     bool,
	cameras:        bool,
	physics_2d:     bool,
	physics_3d:     bool,
	tilemaps:       bool,
	audio:          bool,
	lights:         bool,
	transform_size: f32,
}

default_settings :: proc() -> Settings {
	return Settings {
		enabled = false,
		transforms = true,
		cameras = true,
		physics_2d = true,
		physics_3d = true,
		tilemaps = true,
		audio = true,
		lights = true,
		transform_size = 24,
	}
}

// draw_scene renders enabled debug visualization for the active scene cameras.
// It owns its raylib mode boundaries so game systems can call it after normal
// scene rendering without tracking whether the scene is 2D or 3D.
draw_scene :: proc(world: ^ecs.World, settings: Settings) {
	if !settings.enabled {return}
	drew_2d := draw_scene_2d(world, settings)
	drew_3d := draw_3d_gizmos(world, settings)
	if !drew_2d && !drew_3d {
		draw_scene_screen_2d(world, settings)
	}
}

draw_scene_2d :: proc(world: ^ecs.World, settings: Settings) -> bool {
	if !settings.enabled {return false}
	entity, camera_component, found := ecs.active_camera_2d(world)
	if !found {return false}
	transform, has_transform := ecs.get_transform(world, entity)
	if !has_transform {return false}

	camera := rl.Camera2D {
		offset   = camera_component.offset,
		target   = {transform.position[0], transform.position[1]},
		rotation = camera_component.rotation,
		zoom     = camera_component.zoom,
	}
	rl.BeginMode2D(camera)
	if settings.tilemaps {draw_tilemap_colliders_2d(world)}
	if settings.physics_2d {draw_physics_2d(world)}
	if settings.cameras {draw_cameras_2d(world)}
	if settings.audio {draw_audio_2d(world)}
	if settings.lights {draw_lights_2d(world)}
	if settings.transforms {draw_transforms_2d(world, normalized_transform_size(settings))}
	rl.EndMode2D()
	return true
}

draw_3d_gizmos :: proc(world: ^ecs.World, settings: Settings) -> bool {
	if !settings.enabled {return false}
	entity, camera_component, found := ecs.active_camera_3d(world)
	if !found {return false}
	transform, has_transform := ecs.get_transform(world, entity)
	if !has_transform {return false}

	camera := rl.Camera3D {
		position   = transform.position,
		target     = camera_component.target,
		up         = camera_component.up,
		fovy       = camera_component.fovy,
		projection = .PERSPECTIVE,
	}
	rl.BeginMode3D(camera)
	if settings.physics_3d {draw_physics_3d(world)}
	if settings.cameras {draw_cameras_3d(world)}
	if settings.audio {draw_audio_3d(world)}
	if settings.lights {draw_lights_3d(world)}
	if settings.transforms {draw_transforms_3d(world, normalized_transform_size(settings) / 24)}
	rl.EndMode3D()
	return true
}

draw_scene_screen_2d :: proc(world: ^ecs.World, settings: Settings) {
	if settings.tilemaps {draw_tilemap_colliders_2d(world)}
	if settings.physics_2d {draw_physics_2d(world)}
	if settings.cameras {draw_cameras_2d(world)}
	if settings.audio {draw_audio_2d(world)}
	if settings.lights {draw_lights_2d(world)}
	if settings.transforms {draw_transforms_2d(world, normalized_transform_size(settings))}
}

draw_transforms_2d :: proc(world: ^ecs.World, size: f32) {
	for entity in ecs.entities_with_component(world, "Transform") {
		transform, found := ecs.get_transform(world, entity)
		if !found {continue}
		position := rl.Vector2{transform.position[0], transform.position[1]}
		rl.DrawCircleV(position, 3, rl.WHITE)
		rl.DrawLineEx(position, {position.x + size, position.y}, 2, rl.RED)
		rl.DrawLineEx(position, {position.x, position.y + size}, 2, rl.GREEN)
	}
}

draw_transforms_3d :: proc(world: ^ecs.World, size: f32) {
	for entity in ecs.entities_with_component(world, "Transform") {
		transform, found := ecs.get_transform(world, entity)
		if !found {continue}
		position := rl.Vector3(transform.position)
		rl.DrawLine3D(position, position + rl.Vector3{size, 0, 0}, rl.RED)
		rl.DrawLine3D(position, position + rl.Vector3{0, size, 0}, rl.GREEN)
		rl.DrawLine3D(position, position + rl.Vector3{0, 0, size}, rl.BLUE)
	}
}

draw_cameras_2d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "Camera2D") {
		transform, has_transform := ecs.get_transform(world, entity)
		camera, has_camera := ecs.get_camera_2d(world, entity)
		if !has_transform || !has_camera {continue}
		color := rl.GOLD if camera.active else rl.GRAY
		position := rl.Vector2{transform.position[0], transform.position[1]}
		rl.DrawCircleLines(i32(position.x), i32(position.y), 10, color)
		rl.DrawLineEx({position.x - 14, position.y}, {position.x + 14, position.y}, 1, color)
		rl.DrawLineEx({position.x, position.y - 14}, {position.x, position.y + 14}, 1, color)
	}
}

draw_cameras_3d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "Camera3D") {
		transform, has_transform := ecs.get_transform(world, entity)
		camera, has_camera := ecs.get_camera_3d(world, entity)
		if !has_transform || !has_camera {continue}
		color := rl.GOLD if camera.active else rl.GRAY
		rl.DrawSphereWires(transform.position, 0.15, 8, 4, color)
		rl.DrawLine3D(transform.position, camera.target, color)
	}
}

draw_physics_2d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "BoxCollider2D") {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_box_collider_2d(world, entity)
		if !has_transform || !has_collider {continue}
		width := collider.size[0] * abs_f32(transform.scale[0])
		height := collider.size[1] * abs_f32(transform.scale[1])
		rect := rl.Rectangle {
			transform.position[0] - width * 0.5,
			transform.position[1] - height * 0.5,
			width,
			height,
		}
		rl.DrawRectangleLinesEx(rect, 2, rl.LIME)
	}
	for entity in ecs.entities_with_component(world, "CircleCollider2D") {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_circle_collider_2d(world, entity)
		if !has_transform || !has_collider {continue}
		scale := max_f32(abs_f32(transform.scale[0]), abs_f32(transform.scale[1]))
		rl.DrawCircleLines(
			i32(transform.position[0]),
			i32(transform.position[1]),
			collider.radius * scale,
			rl.LIME,
		)
	}
	for entity in ecs.entities_with_component(world, "TopDownController") {
		transform, has_transform := ecs.get_transform(world, entity)
		controller, has_controller := ecs.get_top_down_controller(world, entity)
		if !has_transform || !has_controller {continue}
		rect := rl.Rectangle {
			transform.position[0] - controller.size[0] * 0.5,
			transform.position[1] - controller.size[1] * 0.5,
			controller.size[0],
			controller.size[1],
		}
		rl.DrawRectangleLinesEx(rect, 1, rl.YELLOW)
	}
}

draw_tilemap_colliders_2d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "TilemapCollider") {
		transform, has_transform := ecs.get_transform(world, entity)
		tilemap, has_tilemap := ecs.get_tilemap_renderer(world, entity)
		collider, has_collider := ecs.get_tilemap_collider(world, entity)
		if !has_transform || !has_tilemap || !has_collider {continue}
		tile_width := tilemap.tile_size[0] * transform.scale[0]
		tile_height := tilemap.tile_size[1] * transform.scale[1]
		if tile_width == 0 || tile_height == 0 {continue}
		for tile in tilemap.tiles {
			if !collider.solid_tiles[tile.index] {continue}
			collision := ecs.tilemap_tile_collision_rect(tilemap, tile.index)
			rect := rl.Rectangle {
				transform.position[0] + (f32(tile.x) + collision.offset[0]) * tile_width,
				transform.position[1] + (f32(tile.y) + collision.offset[1]) * tile_height,
				tile_width * collision.size[0],
				tile_height * collision.size[1],
			}
			rl.DrawRectangleLinesEx(rect, 1, rl.SKYBLUE)
		}
	}
}

draw_physics_3d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "BoxCollider") {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_box_collider(world, entity)
		if !has_transform || !has_collider {continue}
		half := rl.Vector3 {
			collider.size[0] * abs_f32(transform.scale[0]) * 0.5,
			collider.size[1] * abs_f32(transform.scale[1]) * 0.5,
			collider.size[2] * abs_f32(transform.scale[2]) * 0.5,
		}
		box := rl.BoundingBox {
			min = transform.position - half,
			max = transform.position + half,
		}
		rl.DrawBoundingBox(box, rl.LIME if collider.is_static else rl.YELLOW)
	}
	for entity in ecs.entities_with_component(world, "SphereCollider") {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_sphere_collider(world, entity)
		if !has_transform || !has_collider {continue}
		scale := max_f32(
			max_f32(abs_f32(transform.scale[0]), abs_f32(transform.scale[1])),
			abs_f32(transform.scale[2]),
		)
		rl.DrawSphereWires(
			transform.position,
			collider.radius * scale,
			12,
			8,
			rl.LIME if collider.is_static else rl.YELLOW,
		)
	}
	for entity in ecs.entities_with_component(world, "CharacterController") {
		transform, has_transform := ecs.get_transform(world, entity)
		controller, has_controller := ecs.get_character_controller(world, entity)
		if !has_transform || !has_controller {continue}
		center := rl.Vector3 {
			transform.position[0],
			transform.position[1] - controller.eye_height + controller.height * 0.5,
			transform.position[2],
		}
		rl.DrawCylinderWires(
			center,
			controller.radius,
			controller.radius,
			controller.height,
			12,
			rl.ORANGE,
		)
	}
}

draw_audio_2d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "AudioListener") {
		transform, has_transform := ecs.get_transform(world, entity)
		listener, has_listener := ecs.get_audio_listener(world, entity)
		if !has_transform || !has_listener {continue}
		color := rl.VIOLET if listener.active else rl.GRAY
		rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), 14, color)
	}
	for entity in ecs.entities_with_component(world, "AudioPlayer") {
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_transform {continue}
		for instance_name in ecs.component_instance_names(world, entity, "AudioPlayer") {
			player, has_player := ecs.get_audio_player(world, entity, instance_name)
			if !has_player {continue}
			rl.DrawCircleLines(
				i32(transform.position[0]),
				i32(transform.position[1]),
				player.min_distance,
				rl.PINK,
			)
			if player.spatial {rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), player.max_distance, rl.MAROON)}
		}
	}
}

draw_audio_3d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "AudioListener") {
		transform, has_transform := ecs.get_transform(world, entity)
		listener, has_listener := ecs.get_audio_listener(world, entity)
		if !has_transform || !has_listener {continue}
		rl.DrawSphereWires(
			transform.position,
			0.25,
			8,
			4,
			rl.VIOLET if listener.active else rl.GRAY,
		)
	}
	for entity in ecs.entities_with_component(world, "AudioPlayer") {
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_transform {continue}
		for instance_name in ecs.component_instance_names(world, entity, "AudioPlayer") {
			player, has_player := ecs.get_audio_player(world, entity, instance_name)
			if !has_player {continue}
			rl.DrawSphereWires(transform.position, player.min_distance, 12, 6, rl.PINK)
			if player.spatial {rl.DrawSphereWires(transform.position, player.max_distance, 16, 8, rl.MAROON)}
		}
	}
}

draw_lights_2d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "AmbientLight") {
		transform, has_transform := ecs.get_transform(world, entity)
		light, has_light := ecs.get_ambient_light(world, entity)
		if !has_transform || !has_light {continue}
		position := rl.Vector2{transform.position[0], transform.position[1]}
		color := light_color(light.color, light.intensity)
		rl.DrawCircleLines(i32(position.x), i32(position.y), 12, color)
		rl.DrawCircleV(position, 3, color)
	}
	for entity in ecs.entities_with_component(world, "DirectionalLight") {
		transform, has_transform := ecs.get_transform(world, entity)
		light, has_light := ecs.get_directional_light(world, entity)
		if !has_light {continue}
		position := rl.Vector2{}
		if has_transform {position = {transform.position[0], transform.position[1]}}
		direction := normalize2({light.direction[0], light.direction[1]})
		color := light_color(light.color, light.intensity)
		end := rl.Vector2{position.x + direction.x * 48, position.y + direction.y * 48}
		rl.DrawCircleLines(i32(position.x), i32(position.y), 10, color)
		rl.DrawLineEx(position, end, 2, color)
		draw_arrow_head_2d(end, direction, color)
	}
	for entity in ecs.entities_with_component(world, "PointLight") {
		transform, has_transform := ecs.get_transform(world, entity)
		light, has_light := ecs.get_point_light(world, entity)
		if !has_transform || !has_light {continue}
		position := rl.Vector2{transform.position[0], transform.position[1]}
		color := light_color(light.color, light.intensity)
		rl.DrawCircleLines(i32(position.x), i32(position.y), light.range, rl.Fade(color, 0.45))
		rl.DrawCircleV(position, 4, color)
	}
	for entity in ecs.entities_with_component(world, "SpotLight") {
		transform, has_transform := ecs.get_transform(world, entity)
		light, has_light := ecs.get_spot_light(world, entity)
		if !has_transform || !has_light {continue}
		position := rl.Vector2{transform.position[0], transform.position[1]}
		direction := normalize2({light.direction[0], light.direction[1]})
		color := light_color(light.color, light.intensity)
		half_angle := light.outer_angle * f32(math.PI / 180)
		perp := rl.Vector2{-direction.y, direction.x}
		cone_center := rl.Vector2 {
			position.x + direction.x * light.range,
			position.y + direction.y * light.range,
		}
		cone_radius := f32(math.tan(f64(half_angle))) * light.range
		left := rl.Vector2 {
			cone_center.x + perp.x * cone_radius,
			cone_center.y + perp.y * cone_radius,
		}
		right := rl.Vector2 {
			cone_center.x - perp.x * cone_radius,
			cone_center.y - perp.y * cone_radius,
		}
		rl.DrawCircleV(position, 4, color)
		rl.DrawLineEx(position, cone_center, 1, color)
		rl.DrawLineEx(position, left, 1, rl.Fade(color, 0.75))
		rl.DrawLineEx(position, right, 1, rl.Fade(color, 0.75))
		rl.DrawLineEx(left, right, 1, rl.Fade(color, 0.45))
	}
}

draw_lights_3d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "AmbientLight") {
		transform, has_transform := ecs.get_transform(world, entity)
		light, has_light := ecs.get_ambient_light(world, entity)
		if !has_transform || !has_light {continue}
		color := light_color(light.color, light.intensity)
		rl.DrawSphere(transform.position, 0.16, rl.Fade(color, 0.65))
		rl.DrawSphereWires(transform.position, 0.22, 10, 5, color)
	}
	for entity in ecs.entities_with_component(world, "DirectionalLight") {
		transform, has_transform := ecs.get_transform(world, entity)
		light, has_light := ecs.get_directional_light(world, entity)
		if !has_light {continue}
		position := rl.Vector3{}
		if has_transform {position = transform.position}
		direction := normalize3(rl.Vector3(light.direction))
		color := light_color(light.color, light.intensity)
		end := vec3_add(position, vec3_scale(direction, 1.5))
		rl.DrawSphere(position, 0.13, rl.Fade(color, 0.65))
		rl.DrawSphereWires(position, 0.18, 8, 4, color)
		rl.DrawLine3D(position, end, color)
		draw_arrow_head_3d(end, direction, color)
	}
	for entity in ecs.entities_with_component(world, "PointLight") {
		transform, has_transform := ecs.get_transform(world, entity)
		light, has_light := ecs.get_point_light(world, entity)
		if !has_transform || !has_light {continue}
		color := light_color(light.color, light.intensity)
		rl.DrawSphere(transform.position, 0.14, rl.Fade(color, 0.75))
		rl.DrawSphereWires(transform.position, 0.2, 8, 4, color)
		rl.DrawSphereWires(transform.position, light.range, 18, 10, rl.Fade(color, 0.35))
	}
	for entity in ecs.entities_with_component(world, "SpotLight") {
		transform, has_transform := ecs.get_transform(world, entity)
		light, has_light := ecs.get_spot_light(world, entity)
		if !has_transform || !has_light {continue}
		color := light_color(light.color, light.intensity)
		direction := normalize3(rl.Vector3(light.direction))
		center := vec3_add(transform.position, vec3_scale(direction, light.range))
		radius := f32(math.tan(f64(light.outer_angle * f32(math.PI / 180)))) * light.range
		right, up := cone_basis(direction)
		rl.DrawSphere(transform.position, 0.16, rl.Fade(color, 0.75))
		rl.DrawSphereWires(transform.position, 0.22, 8, 4, color)
		rl.DrawLine3D(transform.position, center, color)
		draw_cone_ring_3d(transform.position, center, right, up, radius, color)
	}
}

draw_arrow_head_2d :: proc(tip, direction: rl.Vector2, color: rl.Color) {
	perp := rl.Vector2{-direction.y, direction.x}
	back := rl.Vector2{tip.x - direction.x * 9, tip.y - direction.y * 9}
	rl.DrawLineEx(tip, {back.x + perp.x * 5, back.y + perp.y * 5}, 2, color)
	rl.DrawLineEx(tip, {back.x - perp.x * 5, back.y - perp.y * 5}, 2, color)
}

draw_arrow_head_3d :: proc(tip, direction: rl.Vector3, color: rl.Color) {
	right, up := cone_basis(direction)
	back := vec3_add(tip, vec3_scale(direction, -0.22))
	rl.DrawLine3D(tip, vec3_add(back, vec3_scale(right, 0.09)), color)
	rl.DrawLine3D(tip, vec3_add(back, vec3_scale(right, -0.09)), color)
	rl.DrawLine3D(tip, vec3_add(back, vec3_scale(up, 0.09)), color)
	rl.DrawLine3D(tip, vec3_add(back, vec3_scale(up, -0.09)), color)
}

draw_cone_ring_3d :: proc(apex, center, right, up: rl.Vector3, radius: f32, color: rl.Color) {
	segments := 24
	previous := cone_ring_point(center, right, up, radius, 0, segments)
	cardinal_step := segments / 4
	for index := 1; index <= segments; index += 1 {
		point := cone_ring_point(center, right, up, radius, index, segments)
		rl.DrawLine3D(previous, point, rl.Fade(color, 0.45))
		if (index - 1) % cardinal_step == 0 {
			rl.DrawLine3D(apex, previous, rl.Fade(color, 0.75))
		}
		previous = point
	}
}

cone_ring_point :: proc(
	center, right, up: rl.Vector3,
	radius: f32,
	index, segments: int,
) -> rl.Vector3 {
	angle := f32(index) / f32(segments) * f32(math.PI * 2)
	return vec3_add(
		center,
		vec3_add(
			vec3_scale(right, f32(math.cos(f64(angle))) * radius),
			vec3_scale(up, f32(math.sin(f64(angle))) * radius),
		),
	)
}

cone_basis :: proc(direction: rl.Vector3) -> (rl.Vector3, rl.Vector3) {
	reference := rl.Vector3{0, 1, 0}
	if abs_f32(direction.y) > 0.92 {
		reference = {1, 0, 0}
	}
	right := normalize3(cross3(reference, direction))
	up := normalize3(cross3(direction, right))
	return right, up
}

light_color :: proc(color: ecs.Color, intensity: f32) -> rl.Color {
	alpha := u8(255)
	if intensity <= 0 {
		alpha = 120
	}
	return rl.Color{color.r, color.g, color.b, alpha}
}

normalize2 :: proc(value: rl.Vector2) -> rl.Vector2 {
	length := f32(math.sqrt(f64(value.x * value.x + value.y * value.y)))
	if length <= 0.0001 {return {1, 0}}
	return {value.x / length, value.y / length}
}

normalize3 :: proc(value: rl.Vector3) -> rl.Vector3 {
	length := f32(math.sqrt(f64(value.x * value.x + value.y * value.y + value.z * value.z)))
	if length <= 0.0001 {return {0, -1, 0}}
	return {value.x / length, value.y / length, value.z / length}
}

cross3 :: proc(a, b: rl.Vector3) -> rl.Vector3 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

vec3_add :: proc(a, b: rl.Vector3) -> rl.Vector3 {
	return {a.x + b.x, a.y + b.y, a.z + b.z}
}

vec3_scale :: proc(value: rl.Vector3, scale: f32) -> rl.Vector3 {
	return {value.x * scale, value.y * scale, value.z * scale}
}

abs_f32 :: proc(value: f32) -> f32 {
	if value < 0 {return -value}
	return value
}

max_f32 :: proc(first, second: f32) -> f32 {
	if first > second {return first}
	return second
}

normalized_transform_size :: proc(settings: Settings) -> f32 {
	if settings.transform_size > 0 {return settings.transform_size}
	return 24
}
