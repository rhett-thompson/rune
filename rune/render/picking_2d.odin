package render

import "core:math"
import "core:slice"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:particles"
import rl "vendor:raylib"

// scene_pick_2d returns the topmost rendered bounds at a world-space point.
// It follows the same hierarchy and draw ordering as draw_scene_2d. Textures
// and fonts are only borrowed from the asset cache: picking never loads assets
// or emits diagnostics. Sprites and text use their drawn rectangular bounds,
// without sampling transparent pixels or individual glyph coverage. An explicit
// sprite source rectangle supplies bounds without requiring a cached texture.
scene_pick_2d :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, point: [2]f32) -> (ecs.Entity, bool) {
	if world == nil || math.is_nan(point[0]) || math.is_nan(point[1]) || math.is_inf(point[0]) || math.is_inf(point[1]) {return 0, false}
	commands := make([dynamic]Render_2D_Command, context.temp_allocator)
	for root in ecs.root_entities(world) {
		collect_render_commands_2d(world, root, {0, 0}, {1, 1}, 0, &commands)
	}
	slice.sort_by(commands[:], render_command_2d_less)
	for index := len(commands) - 1; index >= 0; index -= 1 {
		command := commands[index]
		if pick_render_command_2d(world, asset_manager, command, point) {return command.entity, true}
	}
	return 0, false
}

@(private)
pick_render_command_2d :: proc(world: ^ecs.World, manager: ^assets.Asset_Manager, command: Render_2D_Command, point: [2]f32) -> bool {
	#partial switch command.kind {
	case .Shape:
		shape, found := ecs.get_shape_renderer_2d(world, command.entity)
		return found && pick_shape_2d(shape, command, point)
	case .Sprite:
		sprite, found := ecs.get_sprite_renderer(world, command.entity)
		if !found || sprite.tint.a == 0 {return false}
		size := [2]f32{sprite.source[2], sprite.source[3]}
		if size[0] <= 0 || size[1] <= 0 {
			if manager == nil {return false}
			texture := manager.missing_texture
			if cached, loaded := manager.textures[sprite.texture]; loaded {
				texture = cached.texture
			} else if _, missing := manager.missing_textures[sprite.texture]; !missing && sprite.texture != "" {
				return false
			}
			size = {f32(texture.width), f32(texture.height)}
		}
		size *= command.scale
		return pick_rectangle_2d(point, command.position, size, sprite.origin * size, command.rotation)
	case .Tilemap:
		tilemap, found := ecs.get_tilemap_renderer(world, command.entity)
		return found && pick_tilemap_2d(manager, tilemap, command, point)
	case .Text:
		text, found := ecs.get_text_renderer(world, command.entity)
		if !found || manager == nil || text.color.a == 0 || len(text.text) == 0 || command.scale[0] <= 0 {return false}
		cached, loaded := manager.fonts[text.font]
		if !loaded || cached.font.baseSize <= 0 || cached.font.glyphCount <= 0 || cached.font.glyphs == nil || cached.font.recs == nil {return false}
		content, _ := strings.clone_to_cstring(text.text, context.temp_allocator)
		measured := rl.MeasureTextEx(cached.font, content, text.font_size * command.scale[0], text.spacing * command.scale[0])
		size := [2]f32{measured.x, measured.y}
		return pick_rectangle_2d(point, command.position, size, text.origin * size, command.rotation)
	case .Particles:
		emitter, found := ecs.get_particle_emitter_2d(world, command.entity)
		if !found {return false}
		for particle in world.particle_states_2d[command.entity].particles {
			size, color := particles.appearance(particle)
			if size <= 0 || color[3] == 0 {continue}
			if emitter.texture != "" {
				if pick_rectangle_2d(point, particle.position, {size, size}, {size/2, size/2}, 0) {return true}
			} else {
				delta := point - particle.position
				if delta[0]*delta[0] + delta[1]*delta[1] <= size*size/4 {return true}
			}
		}
	}
	return false
}

@(private)
pick_rectangle_2d :: proc(point, position, size, origin: [2]f32, rotation: f32) -> bool {
	if size[0] == 0 || size[1] == 0 {return false}
	angle := rotation * (math.PI / 180)
	cosine, sine := math.cos(angle), math.sin(angle)
	delta := point - position
	local := [2]f32{delta[0]*cosine + delta[1]*sine, -delta[0]*sine + delta[1]*cosine} + origin
	return local[0] >= min(f32(0), size[0]) && local[0] <= max(f32(0), size[0]) &&
	       local[1] >= min(f32(0), size[1]) && local[1] <= max(f32(0), size[1])
}

@(private)
pick_triangle_2d :: proc(point, a, b, c: [2]f32) -> bool {
	cross := (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0])
	if cross == 0 {return false}
	ab := (b[0]-a[0])*(point[1]-a[1]) - (b[1]-a[1])*(point[0]-a[0])
	bc := (c[0]-b[0])*(point[1]-b[1]) - (c[1]-b[1])*(point[0]-b[0])
	ca := (a[0]-c[0])*(point[1]-c[1]) - (a[1]-c[1])*(point[0]-c[0])
	return (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0)
}

@(private)
pick_shape_2d :: proc(shape: ecs.ShapeRenderer2D, command: Render_2D_Command, point: [2]f32) -> bool {
	if shape.color.a == 0 || command.scale[0] == 0 || command.scale[1] == 0 {return false}
	// Match draw_shape_2d's polygon and world-space mitered outlines, including
	// nonuniform/reflected scale and the unfilled interior of outlined shapes.
	points: [64][2]f32
	count := 4 if shape.shape == .rectangle else len(points)
	size := shape.size if shape.shape == .rectangle else [2]f32{shape.radius * 2, shape.radius * 2}
	angle := command.rotation * (math.PI / 180)
	cosine, sine := math.cos(angle), math.sin(angle)
	for i in 0..<count {
		local: [2]f32
		if shape.shape == .rectangle {
			corners := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
			local = corners[i] * size
		} else {
			theta := f32(i) * (2 * math.PI / f32(count))
			local = {shape.radius * (1 + math.cos(theta)), shape.radius * (1 + math.sin(theta))}
		}
		local = (local - shape.origin * size) * command.scale
		points[i] = command.position + [2]f32{local[0]*cosine - local[1]*sine, local[0]*sine + local[1]*cosine}
	}
	if shape.filled {
		for i in 1..<count-1 {
			if pick_triangle_2d(point, points[0], points[i], points[i+1]) {return true}
		}
		return false
	}
	offsets: [64][2]f32
	for i in 0..<count {
		previous := points[i] - points[(i+count-1)%count]
		next := points[(i+1)%count] - points[i]
		previous /= math.sqrt(previous[0]*previous[0] + previous[1]*previous[1])
		next /= math.sqrt(next[0]*next[0] + next[1]*next[1])
		normal_a := [2]f32{-previous[1], previous[0]}
		normal_b := [2]f32{-next[1], next[0]}
		denominator := max(f32(0.001), 1 + normal_a[0]*normal_b[0] + normal_a[1]*normal_b[1])
		offsets[i] = (normal_a + normal_b) * (shape.line_width * 0.5 / denominator)
	}
	for i in 0..<count {
		j := (i+1)%count
		a, b := points[i] + offsets[i], points[j] + offsets[j]
		c, d := points[j] - offsets[j], points[i] - offsets[i]
		if pick_triangle_2d(point, a, b, c) || pick_triangle_2d(point, a, c, d) {return true}
	}
	return false
}

@(private)
pick_tilemap_2d :: proc(manager: ^assets.Asset_Manager, tilemap: ecs.TilemapRenderer, command: Render_2D_Command, point: [2]f32) -> bool {
	if manager == nil {return false}
	texture_path, tile_size := tilemap.texture, tilemap.tile_size
	tileset: assets.Tileset_Data
	uses_tileset := tilemap.tileset != ""
	if uses_tileset {
		cached, loaded := manager.tilesets[tilemap.tileset]
		if !loaded {return false}
		tileset = cached.data
		texture_path, tile_size = tileset.texture, {f32(tileset.tile_size[0]), f32(tileset.tile_size[1])}
	}
	texture, loaded := manager.textures[texture_path]
	if !loaded || tile_size[0] <= 0 || tile_size[1] <= 0 {return false}
	columns, rows := i32(f32(texture.texture.width)/tile_size[0]), i32(f32(texture.texture.height)/tile_size[1])
	if columns <= 0 || rows <= 0 {return false}
	for tile in tilemap.tiles {
		size := tile_size
		if uses_tileset {
			definition, exists := tileset.tiles[tile.index]
			if !exists {continue}
			size *= {f32(definition.size[0]), f32(definition.size[1])}
			if f32(definition.source[0])*tile_size[0] + size[0] > f32(texture.texture.width) ||
			   f32(definition.source[1])*tile_size[1] + size[1] > f32(texture.texture.height) {continue}
		} else if tile.index < 0 || tile.index >= columns*rows {continue}
		// draw_tile rotates each destination around its own top left; the tile's
		// grid offset itself remains axis-aligned even on rotated maps.
		position := command.position + [2]f32{f32(tile.x), f32(tile.y)} * tile_size * command.scale
		if pick_rectangle_2d(point, position, size * command.scale, {}, command.rotation) {return true}
	}
	return false
}
