package render

import "core:strings"
import "rune:ecs"
import "rune:assets"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Rendering is intentionally a thin layer over raylib. r3d will live beside
// this package when the engine reaches its 3D milestone.
Renderer :: struct {
	clear_color: [4]u8,
}

// Scene3D_Settings holds presentation options owned by the renderer.
Scene3D_Settings :: struct {
	grid_slices:  i32,
	grid_spacing: f32,
	draw_colliders: bool,
}

init :: proc() -> Renderer {
	return Renderer{clear_color = {245, 245, 245, 255}}
}

// draw_scene_3d owns the raylib 3D mode boundary as well as entity rendering.
// Client code supplies engine data only; it never calls BeginMode3D/EndMode3D.
// draw_scene_3d renders through the active Camera3D entity. A camera needs a
// Transform for its position; target and up live on Camera3D itself.
draw_scene_3d :: proc(world: ^ecs.World, settings: Scene3D_Settings) -> bool {
	return draw_scene_3d_with_assets(world, nil, settings)
}

// draw_scene_3d_with_assets adds asset-backed ModelRenderer support while the
// original draw_scene_3d API remains useful for primitive-only scenes.
draw_scene_3d_with_assets :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, settings: Scene3D_Settings) -> bool {
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
	if settings.grid_slices > 0 {
		spacing := settings.grid_spacing
		if spacing <= 0 { spacing = 1 }
		rl.DrawGrid(settings.grid_slices, spacing)
	}
	draw_world(world, asset_manager)
	if settings.draw_colliders { draw_collision_debug(world) }
	rl.EndMode3D()
	return true
}

// draw_scene_2d renders the sprite hierarchy through the active Camera2D.
// Sprite positions use the Transform X/Y plane; Z is currently ignored.
draw_scene_2d :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager) -> bool {
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
	for root in ecs.root_entities(world) {
		draw_sprite_tree(world, asset_manager, root, {0, 0}, {1, 1}, 0, camera)
	}
	rl.EndMode2D()
	return true
}

draw_sprite_tree :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity, parent_position, parent_scale: [2]f32, parent_rotation: f32, camera: rl.Camera2D) {
	position := parent_position
	scale := parent_scale
	rotation := parent_rotation
	if transform, found := ecs.get_transform(world, entity); found {
		position += {transform.position[0] * parent_scale[0], transform.position[1] * parent_scale[1]}
		scale *= {transform.scale[0], transform.scale[1]}
		rotation += transform.rotation[2]
	}

	if sprite, found := ecs.get_sprite_renderer(world, entity); found {
		texture, _ := assets.texture(asset_manager, sprite.texture)
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		destination := rl.Rectangle{position[0], position[1], source.width * scale[0], source.height * scale[1]}
		origin := rl.Vector2{destination.width * sprite.origin[0], destination.height * sprite.origin[1]}
		rl.DrawTexturePro(texture, source, destination, origin, rotation, rl.WHITE)
	}
	if tilemap, found := ecs.get_tilemap_renderer(world, entity); found {
		draw_tilemap(asset_manager, tilemap, position, scale, rotation, camera)
	}
	if text, found := ecs.get_text_renderer(world, entity); found {
		draw_text(asset_manager, text, position, scale, rotation)
	}

	for child in ecs.child_entities(world, entity) {
		draw_sprite_tree(world, asset_manager, child, position, scale, rotation, camera)
	}
}

draw_tilemap :: proc(asset_manager: ^assets.Asset_Manager, tilemap: ecs.TilemapRenderer, position, scale: [2]f32, rotation: f32, camera: rl.Camera2D) {
	texture, loaded := assets.texture(asset_manager, tilemap.texture)
	if !loaded { return }
	columns := i32(f32(texture.width) / tilemap.tile_size[0])
	rows := i32(f32(texture.height) / tilemap.tile_size[1])
	if columns <= 0 || rows <= 0 { return }
	// Tilemap rotations need a transformed frustum. Keep that uncommon path
	// correct, while axis-aligned maps only submit tiles visible to the camera.
	if rotation != 0 || camera.rotation != 0 || scale[0] <= 0 || scale[1] <= 0 {
		for tile in tilemap.tiles {
			draw_tile(texture, tilemap, tile, position, scale, rotation, columns, rows)
		}
		return
	}
	minimum := rl.GetScreenToWorld2D({}, camera)
	maximum := rl.GetScreenToWorld2D({f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}, camera)
	tile_width := tilemap.tile_size[0] * scale[0]
	tile_height := tilemap.tile_size[1] * scale[1]
	min_x := i32((minimum.x - position[0]) / tile_width) - 1
	max_x := i32((maximum.x - position[0]) / tile_width) + 1
	min_y := i32((minimum.y - position[1]) / tile_height) - 1
	max_y := i32((maximum.y - position[1]) / tile_height) + 1
	if min_x < 0 { min_x = 0 }
	if min_y < 0 { min_y = 0 }
	if max_x >= tilemap.grid_size[0] { max_x = tilemap.grid_size[0] - 1 }
	if max_y >= tilemap.grid_size[1] { max_y = tilemap.grid_size[1] - 1 }
	for y := min_y; y <= max_y; y += 1 {
		for x := min_x; x <= max_x; x += 1 {
			index, found := tilemap.tile_indices[{x, y}]
			if !found { continue }
			draw_tile(texture, tilemap, ecs.Tilemap_Tile{x = x, y = y, index = index}, position, scale, rotation, columns, rows)
		}
	}
}

draw_tile :: proc(texture: rl.Texture2D, tilemap: ecs.TilemapRenderer, tile: ecs.Tilemap_Tile, position, scale: [2]f32, rotation: f32, columns, rows: i32) {
	if tile.index < 0 || tile.index >= columns * rows { return }
	source := rl.Rectangle{
		f32(tile.index % columns) * tilemap.tile_size[0],
		f32(tile.index / columns) * tilemap.tile_size[1],
		tilemap.tile_size[0], tilemap.tile_size[1],
	}
	destination := rl.Rectangle{
		position[0] + f32(tile.x) * source.width * scale[0],
		position[1] + f32(tile.y) * source.height * scale[1],
		source.width * scale[0], source.height * scale[1],
	}
	rl.DrawTexturePro(texture, source, destination, {}, rotation, rl.WHITE)
}

draw_text :: proc(asset_manager: ^assets.Asset_Manager, text: ecs.TextRenderer, position, scale: [2]f32, rotation: f32) {
	font, loaded := assets.font(asset_manager, text.font)
	if !loaded { return }
	content, _ := strings.clone_to_cstring(text.text)
	font_size := text.font_size * scale[0]
	spacing := text.spacing * scale[0]
	measured := rl.MeasureTextEx(font, content, font_size, spacing)
	origin := rl.Vector2{measured.x * text.origin[0], measured.y * text.origin[1]}
	rl.DrawTextPro(font, content, position, origin, rotation, font_size, spacing, to_raylib_color(text.color))
}

// draw_world owns render dispatch for scene entities. Each entity gets an
// isolated matrix scope, so game systems only update component data; they never
// need to pair PushMatrix/PopMatrix or issue renderer-specific draw calls.
draw_world :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager = nil) {
	for entity in ecs.root_entities(world) {
		draw_entity_tree(world, asset_manager, entity)
	}
}

draw_entity_tree :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity) {
	rlgl.PushMatrix()
	if transform, has_transform := ecs.get_transform(world, entity); has_transform {
		apply_transform(transform)
	}

	draw_entity(world, asset_manager, entity)
	for child in ecs.child_entities(world, entity) {
		draw_entity_tree(world, asset_manager, child)
	}
	rlgl.PopMatrix()
}

apply_transform :: proc(transform: ecs.Transform) {
	rlgl.Translatef(transform.position[0], transform.position[1], transform.position[2])
	rlgl.Rotatef(transform.rotation[0], 1, 0, 0)
	rlgl.Rotatef(transform.rotation[1], 0, 1, 0)
	rlgl.Rotatef(transform.rotation[2], 0, 0, 1)
	rlgl.Scalef(transform.scale[0], transform.scale[1], transform.scale[2])
}

draw_entity :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity) {
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity); has_mesh {
		if mesh.primitive == "cube" {
			rl.DrawCube({}, 1, 1, 1, to_raylib_color(mesh.color))
		}
	}
	if sphere, has_sphere := ecs.get_sphere_renderer(world, entity); has_sphere {
		rl.DrawSphere({}, sphere.radius, to_raylib_color(sphere.color))
	}
	if asset_manager != nil {
		if model_renderer, has_model := ecs.get_model_renderer(world, entity); has_model {
			if model, loaded := assets.model(asset_manager, model_renderer.model); loaded {
				rl.DrawModel(model, {}, 1, to_raylib_color(model_renderer.tint))
			}
		}
	}
}

to_raylib_color :: proc(color: ecs.Color) -> rl.Color {
	return rl.Color{color.r, color.g, color.b, color.a}
}

// draw_collision_debug renders built-in collision bounds in the active 3D mode.
draw_collision_debug :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "BoxCollider") {
		collider, has_collider := ecs.get_box_collider(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_collider || !has_transform { continue }
		half := [3]f32{
			collider.size[0] * transform.scale[0] * 0.5,
			collider.size[1] * transform.scale[1] * 0.5,
			collider.size[2] * transform.scale[2] * 0.5,
		}
		box := rl.BoundingBox{min = transform.position - half, max = transform.position + half}
		rl.DrawBoundingBox(box, rl.LIME if collider.is_static else rl.YELLOW)
	}
	for entity in ecs.entities_with_component(world, "SphereCollider") {
		collider, has_collider := ecs.get_sphere_collider(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_collider || !has_transform { continue }
		scale := transform.scale[0]
		if transform.scale[1] > scale { scale = transform.scale[1] }
		if transform.scale[2] > scale { scale = transform.scale[2] }
		rl.DrawSphereWires(transform.position, collider.radius * scale, 12, 8, rl.LIME if collider.is_static else rl.YELLOW)
	}
}
