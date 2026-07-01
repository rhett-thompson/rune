package gizmos

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
	transform_size: f32,
}

default_settings :: proc() -> Settings {
	return Settings{
		enabled = false,
		transforms = true,
		cameras = true,
		physics_2d = true,
		physics_3d = true,
		tilemaps = true,
		audio = true,
		transform_size = 24,
	}
}

// draw_scene renders enabled debug visualization for the active scene cameras.
// It owns its raylib mode boundaries so game systems can call it after normal
// scene rendering without tracking whether the scene is 2D or 3D.
draw_scene :: proc(world: ^ecs.World, settings: Settings) {
	if !settings.enabled { return }
	drew_2d := draw_scene_2d(world, settings)
	drew_3d := draw_scene_3d(world, settings)
	if !drew_2d && !drew_3d {
		draw_scene_screen_2d(world, settings)
	}
}

draw_scene_2d :: proc(world: ^ecs.World, settings: Settings) -> bool {
	if !settings.enabled { return false }
	entity, camera_component, found := ecs.active_camera_2d(world)
	if !found { return false }
	transform, has_transform := ecs.get_transform(world, entity)
	if !has_transform { return false }

	camera := rl.Camera2D{
		offset = camera_component.offset,
		target = {transform.position[0], transform.position[1]},
		rotation = camera_component.rotation,
		zoom = camera_component.zoom,
	}
	rl.BeginMode2D(camera)
	if settings.tilemaps { draw_tilemap_colliders_2d(world) }
	if settings.physics_2d { draw_physics_2d(world) }
	if settings.cameras { draw_cameras_2d(world) }
	if settings.audio { draw_audio_2d(world) }
	if settings.transforms { draw_transforms_2d(world, normalized_transform_size(settings)) }
	rl.EndMode2D()
	return true
}

draw_scene_3d :: proc(world: ^ecs.World, settings: Settings) -> bool {
	if !settings.enabled { return false }
	entity, camera_component, found := ecs.active_camera_3d(world)
	if !found { return false }
	transform, has_transform := ecs.get_transform(world, entity)
	if !has_transform { return false }

	camera := rl.Camera3D{
		position = transform.position,
		target = camera_component.target,
		up = camera_component.up,
		fovy = camera_component.fovy,
		projection = .PERSPECTIVE,
	}
	rl.BeginMode3D(camera)
	if settings.physics_3d { draw_physics_3d(world) }
	if settings.cameras { draw_cameras_3d(world) }
	if settings.audio { draw_audio_3d(world) }
	if settings.transforms { draw_transforms_3d(world, normalized_transform_size(settings) / 24) }
	rl.EndMode3D()
	return true
}

draw_scene_screen_2d :: proc(world: ^ecs.World, settings: Settings) {
	if settings.tilemaps { draw_tilemap_colliders_2d(world) }
	if settings.physics_2d { draw_physics_2d(world) }
	if settings.cameras { draw_cameras_2d(world) }
	if settings.audio { draw_audio_2d(world) }
	if settings.transforms { draw_transforms_2d(world, normalized_transform_size(settings)) }
}

draw_transforms_2d :: proc(world: ^ecs.World, size: f32) {
	for entity in ecs.entities_with_component(world, "Transform") {
		transform, found := ecs.get_transform(world, entity)
		if !found { continue }
		position := rl.Vector2{transform.position[0], transform.position[1]}
		rl.DrawCircleV(position, 3, rl.WHITE)
		rl.DrawLineEx(position, {position.x + size, position.y}, 2, rl.RED)
		rl.DrawLineEx(position, {position.x, position.y + size}, 2, rl.GREEN)
	}
}

draw_transforms_3d :: proc(world: ^ecs.World, size: f32) {
	for entity in ecs.entities_with_component(world, "Transform") {
		transform, found := ecs.get_transform(world, entity)
		if !found { continue }
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
		if !has_transform || !has_camera { continue }
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
		if !has_transform || !has_camera { continue }
		color := rl.GOLD if camera.active else rl.GRAY
		rl.DrawSphereWires(transform.position, 0.15, 8, 4, color)
		rl.DrawLine3D(transform.position, camera.target, color)
	}
}

draw_physics_2d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "BoxCollider2D") {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_box_collider_2d(world, entity)
		if !has_transform || !has_collider { continue }
		width := collider.size[0] * abs_f32(transform.scale[0])
		height := collider.size[1] * abs_f32(transform.scale[1])
		rect := rl.Rectangle{transform.position[0] - width * 0.5, transform.position[1] - height * 0.5, width, height}
		rl.DrawRectangleLinesEx(rect, 2, rl.LIME)
	}
	for entity in ecs.entities_with_component(world, "CircleCollider2D") {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_circle_collider_2d(world, entity)
		if !has_transform || !has_collider { continue }
		scale := max_f32(abs_f32(transform.scale[0]), abs_f32(transform.scale[1]))
		rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), collider.radius * scale, rl.LIME)
	}
	for entity in ecs.entities_with_component(world, "TopDownController") {
		transform, has_transform := ecs.get_transform(world, entity)
		controller, has_controller := ecs.get_top_down_controller(world, entity)
		if !has_transform || !has_controller { continue }
		rect := rl.Rectangle{
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
		if !has_transform || !has_tilemap || !has_collider { continue }
		tile_width := tilemap.tile_size[0] * transform.scale[0]
		tile_height := tilemap.tile_size[1] * transform.scale[1]
		if tile_width == 0 || tile_height == 0 { continue }
		for tile in tilemap.tiles {
			if !collider.solid_tiles[tile.index] { continue }
			rect := rl.Rectangle{
				transform.position[0] + f32(tile.x) * tile_width,
				transform.position[1] + f32(tile.y) * tile_height,
				tile_width,
				tile_height,
			}
			rl.DrawRectangleLinesEx(rect, 1, rl.SKYBLUE)
		}
	}
}

draw_physics_3d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "BoxCollider") {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_box_collider(world, entity)
		if !has_transform || !has_collider { continue }
		half := rl.Vector3{
			collider.size[0] * abs_f32(transform.scale[0]) * 0.5,
			collider.size[1] * abs_f32(transform.scale[1]) * 0.5,
			collider.size[2] * abs_f32(transform.scale[2]) * 0.5,
		}
		box := rl.BoundingBox{min = transform.position - half, max = transform.position + half}
		rl.DrawBoundingBox(box, rl.LIME if collider.is_static else rl.YELLOW)
	}
	for entity in ecs.entities_with_component(world, "SphereCollider") {
		transform, has_transform := ecs.get_transform(world, entity)
		collider, has_collider := ecs.get_sphere_collider(world, entity)
		if !has_transform || !has_collider { continue }
		scale := max_f32(max_f32(abs_f32(transform.scale[0]), abs_f32(transform.scale[1])), abs_f32(transform.scale[2]))
		rl.DrawSphereWires(transform.position, collider.radius * scale, 12, 8, rl.LIME if collider.is_static else rl.YELLOW)
	}
	for entity in ecs.entities_with_component(world, "CharacterController") {
		transform, has_transform := ecs.get_transform(world, entity)
		controller, has_controller := ecs.get_character_controller(world, entity)
		if !has_transform || !has_controller { continue }
		center := rl.Vector3{transform.position[0], transform.position[1] - controller.eye_height + controller.height * 0.5, transform.position[2]}
		rl.DrawCylinderWires(center, controller.radius, controller.radius, controller.height, 12, rl.ORANGE)
	}
}

draw_audio_2d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "AudioListener") {
		transform, has_transform := ecs.get_transform(world, entity)
		listener, has_listener := ecs.get_audio_listener(world, entity)
		if !has_transform || !has_listener { continue }
		color := rl.VIOLET if listener.active else rl.GRAY
		rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), 14, color)
	}
	for entity in ecs.entities_with_component(world, "AudioPlayer") {
		transform, has_transform := ecs.get_transform(world, entity)
		player, has_player := ecs.get_audio_player(world, entity)
		if !has_transform || !has_player { continue }
		rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), player.min_distance, rl.PINK)
		if player.spatial { rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), player.max_distance, rl.MAROON) }
	}
}

draw_audio_3d :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "AudioListener") {
		transform, has_transform := ecs.get_transform(world, entity)
		listener, has_listener := ecs.get_audio_listener(world, entity)
		if !has_transform || !has_listener { continue }
		rl.DrawSphereWires(transform.position, 0.25, 8, 4, rl.VIOLET if listener.active else rl.GRAY)
	}
	for entity in ecs.entities_with_component(world, "AudioPlayer") {
		transform, has_transform := ecs.get_transform(world, entity)
		player, has_player := ecs.get_audio_player(world, entity)
		if !has_transform || !has_player { continue }
		rl.DrawSphereWires(transform.position, player.min_distance, 12, 6, rl.PINK)
		if player.spatial { rl.DrawSphereWires(transform.position, player.max_distance, 16, 8, rl.MAROON) }
	}
}

abs_f32 :: proc(value: f32) -> f32 {
	if value < 0 { return -value }
	return value
}

max_f32 :: proc(first, second: f32) -> f32 {
	if first > second { return first }
	return second
}

normalized_transform_size :: proc(settings: Settings) -> f32 {
	if settings.transform_size > 0 { return settings.transform_size }
	return 24
}
