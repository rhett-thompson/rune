package render

import "core:strings"
import "rune:assets"
import "rune:ecs"
import rl "vendor:raylib"

// Rendering is intentionally a thin layer over raylib for 2D scenes. 3D scene
// rendering lives in rune:r3d_bridge.
Renderer :: struct {
	clear_color: [4]u8,
}

init :: proc() -> Renderer {
	return Renderer{clear_color = {245, 245, 245, 255}}
}

// draw_scene_2d renders the sprite hierarchy through the active Camera2D.
// Sprite positions use the Transform X/Y plane; Z is currently ignored.
draw_scene_2d :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager) -> bool {
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
	for root in ecs.root_entities(world) {
		draw_sprite_tree(world, asset_manager, root, {0, 0}, {1, 1}, 0, camera)
	}
	rl.EndMode2D()
	return true
}

draw_sprite_tree :: proc(
	world: ^ecs.World,
	asset_manager: ^assets.Asset_Manager,
	entity: ecs.Entity,
	parent_position, parent_scale: [2]f32,
	parent_rotation: f32,
	camera: rl.Camera2D,
) {
	position := parent_position
	scale := parent_scale
	rotation := parent_rotation
	if transform, found := ecs.get_transform(world, entity); found {
		position += {
			transform.position[0] * parent_scale[0],
			transform.position[1] * parent_scale[1],
		}
		scale *= {transform.scale[0], transform.scale[1]}
		rotation += transform.rotation[2]
	}

	if sprite, found := ecs.get_sprite_renderer(world, entity); found {
		texture, _ := assets.texture(asset_manager, sprite.texture, "", "SpriteRenderer.texture")
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		destination := rl.Rectangle {
			position[0],
			position[1],
			source.width * scale[0],
			source.height * scale[1],
		}
		origin := rl.Vector2 {
			destination.width * sprite.origin[0],
			destination.height * sprite.origin[1],
		}
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

draw_tilemap :: proc(
	asset_manager: ^assets.Asset_Manager,
	tilemap: ecs.TilemapRenderer,
	position, scale: [2]f32,
	rotation: f32,
	camera: rl.Camera2D,
) {
	texture, loaded := assets.texture(
		asset_manager,
		tilemap.texture,
		"",
		"TilemapRenderer.texture",
	)
	if !loaded {return}
	columns := i32(f32(texture.width) / tilemap.tile_size[0])
	rows := i32(f32(texture.height) / tilemap.tile_size[1])
	if columns <= 0 || rows <= 0 {return}
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
	if min_x < 0 {min_x = 0}
	if min_y < 0 {min_y = 0}
	if max_x >= tilemap.grid_size[0] {max_x = tilemap.grid_size[0] - 1}
	if max_y >= tilemap.grid_size[1] {max_y = tilemap.grid_size[1] - 1}
	for y := min_y; y <= max_y; y += 1 {
		for x := min_x; x <= max_x; x += 1 {
			index, found := tilemap.tile_indices[{x, y}]
			if !found {continue}
			draw_tile(
				texture,
				tilemap,
				ecs.Tilemap_Tile{x = x, y = y, index = index},
				position,
				scale,
				rotation,
				columns,
				rows,
			)
		}
	}
}

draw_tile :: proc(
	texture: rl.Texture2D,
	tilemap: ecs.TilemapRenderer,
	tile: ecs.Tilemap_Tile,
	position, scale: [2]f32,
	rotation: f32,
	columns, rows: i32,
) {
	if tile.index < 0 || tile.index >= columns * rows {return}
	source := rl.Rectangle {
		f32(tile.index % columns) * tilemap.tile_size[0],
		f32(tile.index / columns) * tilemap.tile_size[1],
		tilemap.tile_size[0],
		tilemap.tile_size[1],
	}
	destination := rl.Rectangle {
		position[0] + f32(tile.x) * source.width * scale[0],
		position[1] + f32(tile.y) * source.height * scale[1],
		source.width * scale[0],
		source.height * scale[1],
	}
	rl.DrawTexturePro(texture, source, destination, {}, rotation, rl.WHITE)
}

draw_text :: proc(
	asset_manager: ^assets.Asset_Manager,
	text: ecs.TextRenderer,
	position, scale: [2]f32,
	rotation: f32,
) {
	font, loaded := assets.font(asset_manager, text.font, "", "TextRenderer.font")
	if !loaded {return}
	content, _ := strings.clone_to_cstring(text.text)
	defer delete(content)
	font_size := text.font_size * scale[0]
	spacing := text.spacing * scale[0]
	measured := rl.MeasureTextEx(font, content, font_size, spacing)
	origin := rl.Vector2{measured.x * text.origin[0], measured.y * text.origin[1]}
	rl.DrawTextPro(
		font,
		content,
		position,
		origin,
		rotation,
		font_size,
		spacing,
		to_raylib_color(text.color),
	)
}

to_raylib_color :: proc(color: ecs.Color) -> rl.Color {
	return rl.Color{color.r, color.g, color.b, color.a}
}
