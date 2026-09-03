package render

import "core:fmt"
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
		source := rl.Rectangle {
			sprite.source[0],
			sprite.source[1],
			sprite.source[2],
			sprite.source[3],
		}
		if source.width <= 0 || source.height <= 0 {
			source = {0, 0, f32(texture.width), f32(texture.height)}
		}
		frame_width := source.width
		frame_height := source.height
		if sprite.flip_x {source.width = -source.width}
		if sprite.flip_y {source.height = -source.height}
		destination := rl.Rectangle {
			position[0],
			position[1],
			frame_width * scale[0],
			frame_height * scale[1],
		}
		origin := rl.Vector2 {
			destination.width * sprite.origin[0],
			destination.height * sprite.origin[1],
		}
		rl.DrawTexturePro(
			texture,
			source,
			destination,
			origin,
			rotation,
			to_raylib_color(sprite.tint),
		)
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
	resolved_tilemap := tilemap
	tileset_data: assets.Tileset_Data
	uses_tileset := len(tilemap.tileset) > 0
	if uses_tileset {
		loaded: bool
		tileset_data, _, loaded = assets.tileset(asset_manager, tilemap.tileset)
		if !loaded {return}
		resolved_tilemap.texture = tileset_data.texture
		resolved_tilemap.tile_size = {
			f32(tileset_data.tile_size[0]),
			f32(tileset_data.tile_size[1]),
		}
	}
	texture, loaded := assets.texture(
		asset_manager,
		resolved_tilemap.texture,
		"",
		"TilemapRenderer.texture",
	)
	if !loaded {return}
	columns := i32(f32(texture.width) / resolved_tilemap.tile_size[0])
	rows := i32(f32(texture.height) / resolved_tilemap.tile_size[1])
	if columns <= 0 || rows <= 0 {return}
	maximum_size := [2]i32{1, 1}
	if uses_tileset {maximum_size = tileset_data.max_size}
	// Tilemap rotations need a transformed frustum. Keep that uncommon path
	// correct, while axis-aligned maps only submit tiles visible to the camera.
	if rotation != 0 || camera.rotation != 0 || scale[0] <= 0 || scale[1] <= 0 {
		for tile in resolved_tilemap.tiles {
			draw_tile(
				asset_manager,
				texture,
				resolved_tilemap,
				tile,
				position,
				scale,
				rotation,
				columns,
				rows,
				tileset_data,
				uses_tileset,
			)
		}
		return
	}
	minimum := rl.GetScreenToWorld2D({}, camera)
	maximum := rl.GetScreenToWorld2D({f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}, camera)
	tile_width := resolved_tilemap.tile_size[0] * scale[0]
	tile_height := resolved_tilemap.tile_size[1] * scale[1]
	min_x := i32((minimum.x - position[0]) / tile_width) - maximum_size[0]
	max_x := i32((maximum.x - position[0]) / tile_width) + 1
	min_y := i32((minimum.y - position[1]) / tile_height) - maximum_size[1]
	max_y := i32((maximum.y - position[1]) / tile_height) + 1
	if min_x < 0 {min_x = 0}
	if min_y < 0 {min_y = 0}
	if max_x >= resolved_tilemap.grid_size[0] {max_x = resolved_tilemap.grid_size[0] - 1}
	if max_y >= resolved_tilemap.grid_size[1] {max_y = resolved_tilemap.grid_size[1] - 1}
	for y := min_y; y <= max_y; y += 1 {
		for x := min_x; x <= max_x; x += 1 {
			index, found := resolved_tilemap.tile_indices[{x, y}]
			if !found {continue}
			draw_tile(
				asset_manager,
				texture,
				resolved_tilemap,
				ecs.Tilemap_Tile{x = x, y = y, index = index},
				position,
				scale,
				rotation,
				columns,
				rows,
				tileset_data,
				uses_tileset,
			)
		}
	}
}

draw_tile :: proc(
	asset_manager: ^assets.Asset_Manager,
	texture: rl.Texture2D,
	tilemap: ecs.TilemapRenderer,
	tile: ecs.Tilemap_Tile,
	position, scale: [2]f32,
	rotation: f32,
	columns, rows: i32,
	tileset: assets.Tileset_Data,
	uses_tileset: bool,
) {
	source: rl.Rectangle
	if uses_tileset {
		definition, found := tileset.tiles[tile.index]
		if !found {
			assets.report_failure(
				asset_manager,
				assets.Diagnostic {
					kind = .Tileset,
					operation = .Load,
					source_path = tilemap.tileset,
					field = fmt.tprintf("tile %d", tile.index),
					asset_path = tilemap.tileset,
					detail = "tile ID is not defined by the tileset",
				},
			)
			return
		}
		source = {
			f32(definition.source[0]) * tilemap.tile_size[0],
			f32(definition.source[1]) * tilemap.tile_size[1],
			f32(definition.size[0]) * tilemap.tile_size[0],
			f32(definition.size[1]) * tilemap.tile_size[1],
		}
		if source.x + source.width > f32(texture.width) ||
		   source.y + source.height > f32(texture.height) {
			assets.report_failure(
				asset_manager,
				assets.Diagnostic {
					kind = .Tileset,
					operation = .Load,
					source_path = tilemap.tileset,
					field = fmt.tprintf("tile %d", tile.index),
					asset_path = tilemap.tileset,
					detail = "tile source rectangle is outside the texture",
				},
			)
			return
		}
	} else {
		if tile.index < 0 || tile.index >= columns * rows {return}
		source = {
			f32(tile.index % columns) * tilemap.tile_size[0],
			f32(tile.index / columns) * tilemap.tile_size[1],
			tilemap.tile_size[0],
			tilemap.tile_size[1],
		}
	}
	destination := rl.Rectangle {
		position[0] + f32(tile.x) * tilemap.tile_size[0] * scale[0],
		position[1] + f32(tile.y) * tilemap.tile_size[1] * scale[1],
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
