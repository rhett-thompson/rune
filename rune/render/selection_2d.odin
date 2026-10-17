package render

import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:particles"
import rl "vendor:raylib"

// scene_selection_bounds_2d returns the canvas-space bounds of this entity's
// supported 2D visuals, using draw_scene_2d's hierarchy and cached asset data.
// Children are excluded. This CPU query never loads assets or changes rendering.
scene_selection_bounds_2d :: proc(world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity, camera: rl.Camera2D) -> (rl.Rectangle, bool) {
	if world == nil || !ecs.is_enabled(world, entity) ||
	   !selection_finite_2d(camera.offset) || !selection_finite_2d(camera.target) ||
	   !selection_scalar_2d(camera.rotation) || !selection_scalar_2d(camera.zoom) || camera.zoom == 0 {return {}, false}
	commands := make([dynamic]Render_2D_Command, context.temp_allocator)
	for root in ecs.root_entities(world) {
		collect_render_commands_2d(world, root, {0, 0}, {1, 1}, 0, &commands)
	}
	bounds := Selection_Bounds_2D{camera = camera}
	for command in commands {
		if command.entity != entity {continue}
		selection_command_2d(world, manager, command, &bounds)
	}
	if !bounds.found {return {}, false}
	size := bounds.maximum - bounds.minimum
	if !selection_finite_2d(size) || size[0] <= 0 || size[1] <= 0 {return {}, false}
	return {bounds.minimum[0], bounds.minimum[1], size[0], size[1]}, true
}

@(private)
Selection_Bounds_2D :: struct {
	camera: rl.Camera2D,
	minimum, maximum: [2]f32,
	found: bool,
}

@(private)
selection_scalar_2d :: proc(value: f32) -> bool {return !math.is_nan(value) && !math.is_inf(value)}

@(private)
selection_finite_2d :: proc(value: [2]f32) -> bool {return selection_scalar_2d(value[0]) && selection_scalar_2d(value[1])}

@(private)
selection_point_2d :: proc(bounds: ^Selection_Bounds_2D, point: [2]f32) {
	if !selection_finite_2d(point) {return}
	projected := rl.GetWorldToScreen2D(point, bounds.camera)
	if !selection_finite_2d(projected) {return}
	if !bounds.found {bounds.minimum = projected; bounds.maximum = projected; bounds.found = true; return}
	for axis in 0..<2 {
		bounds.minimum[axis] = min(bounds.minimum[axis], projected[axis])
		bounds.maximum[axis] = max(bounds.maximum[axis], projected[axis])
	}
}

@(private)
selection_rectangle_2d :: proc(bounds: ^Selection_Bounds_2D, position, size, origin: [2]f32, rotation: f32) {
	if !selection_finite_2d(position) || !selection_finite_2d(size) || !selection_finite_2d(origin) ||
	   !selection_scalar_2d(rotation) || size[0] == 0 || size[1] == 0 {return}
	angle := rotation * (math.PI / 180)
	cosine, sine := math.cos(angle), math.sin(angle)
	corners := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	for corner in corners {
		local := corner * size - origin
		selection_point_2d(bounds, position + [2]f32{local[0]*cosine - local[1]*sine, local[0]*sine + local[1]*cosine})
	}
}

@(private)
selection_command_2d :: proc(world: ^ecs.World, manager: ^assets.Asset_Manager, command: Render_2D_Command, bounds: ^Selection_Bounds_2D) {
	if !selection_finite_2d(command.position) || !selection_finite_2d(command.scale) || !selection_scalar_2d(command.rotation) {return}
	#partial switch command.kind {
	case .Shape:
		if shape, found := ecs.get_shape_renderer_2d(world, command.entity); found {selection_shape_2d(shape, command, bounds)}
	case .Sprite:
		sprite, found := ecs.get_sprite_renderer(world, command.entity)
		if !found || sprite.tint.a == 0 {return}
		size := [2]f32{sprite.source[2], sprite.source[3]}
		if size[0] <= 0 || size[1] <= 0 {
			if manager == nil {return}
			texture := manager.missing_texture
			if cached, loaded := manager.textures[sprite.texture]; loaded {
				texture = cached.texture
			} else if _, missing := manager.missing_textures[sprite.texture]; !missing && sprite.texture != "" {return}
			size = {f32(texture.width), f32(texture.height)}
		}
		size *= command.scale
		selection_rectangle_2d(bounds, command.position, size, sprite.origin*size, command.rotation)
	case .Text:
		text, found := ecs.get_text_renderer(world, command.entity)
		if !found || manager == nil || text.color.a == 0 || len(text.text) == 0 || command.scale[0] <= 0 {return}
		cached, loaded := manager.fonts[text.font]
		if !loaded || cached.font.baseSize <= 0 || cached.font.glyphCount <= 0 || cached.font.glyphs == nil || cached.font.recs == nil {return}
		content, _ := strings.clone_to_cstring(text.text, context.temp_allocator)
		measured := rl.MeasureTextEx(cached.font, content, text.font_size*command.scale[0], text.spacing*command.scale[0])
		size := [2]f32{measured.x, measured.y}
		selection_rectangle_2d(bounds, command.position, size, text.origin*size, command.rotation)
	case .Tilemap:
		if tilemap, found := ecs.get_tilemap_renderer(world, command.entity); found {selection_tilemap_2d(manager, tilemap, command, bounds)}
	case .Particles:
		emitter, found := ecs.get_particle_emitter_2d(world, command.entity)
		if !found {return}
		for particle in world.particle_states_2d[command.entity].particles {
			size, color := particles.appearance(particle)
			if !selection_scalar_2d(size) || size <= 0 || color[3] == 0 {continue}
			// Circular and square particles have the same unrotated extent. A
			// camera rotation affects square corners, while circles stay circular.
			if emitter.texture != "" {
				selection_rectangle_2d(bounds, particle.position, {size, size}, {size/2, size/2}, 0)
			} else {
				center := rl.GetWorldToScreen2D(particle.position, bounds.camera)
				radius := size*math.abs(bounds.camera.zoom)/2
				if !selection_finite_2d(particle.position) || !selection_finite_2d(center) || !selection_scalar_2d(radius) {continue}
				minimum, maximum := center-[2]f32{radius, radius}, center+[2]f32{radius, radius}
				if !bounds.found {bounds.minimum=minimum; bounds.maximum=maximum; bounds.found=true} else {
					for axis in 0..<2 {bounds.minimum[axis]=min(bounds.minimum[axis],minimum[axis]); bounds.maximum[axis]=max(bounds.maximum[axis],maximum[axis])}
				}
			}
		}
	}
}

@(private)
selection_shape_2d :: proc(shape: ecs.ShapeRenderer2D, command: Render_2D_Command, bounds: ^Selection_Bounds_2D) {
	if shape.color.a == 0 || command.scale[0] == 0 || command.scale[1] == 0 {return}
	points: [64][2]f32
	count := 4 if shape.shape == .rectangle else len(points)
	size := shape.size if shape.shape == .rectangle else [2]f32{shape.radius*2, shape.radius*2}
	if !selection_finite_2d(size) || size[0] <= 0 || size[1] <= 0 || !selection_finite_2d(shape.origin) ||
	   (!shape.filled && (!selection_scalar_2d(shape.line_width) || shape.line_width <= 0)) {return}
	angle := command.rotation * (math.PI / 180)
	cosine, sine := math.cos(angle), math.sin(angle)
	for i in 0..<count {
		local: [2]f32
		if shape.shape == .rectangle {
			corners := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
			local = corners[i]*size
		} else {
			theta := f32(i)*(2*math.PI/f32(count))
			local = {shape.radius*(1+math.cos(theta)), shape.radius*(1+math.sin(theta))}
		}
		local = (local-shape.origin*size)*command.scale
		points[i] = command.position + [2]f32{local[0]*cosine-local[1]*sine, local[0]*sine+local[1]*cosine}
		if !selection_finite_2d(points[i]) {return}
	}
	for i in 0..<count {
		if shape.filled {selection_point_2d(bounds, points[i]); continue}
		previous, next := points[i]-points[(i+count-1)%count], points[(i+1)%count]-points[i]
		previous_length := math.sqrt(previous[0]*previous[0]+previous[1]*previous[1])
		next_length := math.sqrt(next[0]*next[0]+next[1]*next[1])
		if previous_length <= 0 || next_length <= 0 || !selection_scalar_2d(previous_length) || !selection_scalar_2d(next_length) {return}
		previous /= previous_length; next /= next_length
		normal_a, normal_b := [2]f32{-previous[1], previous[0]}, [2]f32{-next[1], next[0]}
		denominator := max(f32(0.001), 1+normal_a[0]*normal_b[0]+normal_a[1]*normal_b[1])
		offset := (normal_a+normal_b)*(shape.line_width*0.5/denominator)
		selection_point_2d(bounds, points[i]+offset)
		selection_point_2d(bounds, points[i]-offset)
	}
}

@(private)
selection_tilemap_2d :: proc(manager: ^assets.Asset_Manager, tilemap: ecs.TilemapRenderer, command: Render_2D_Command, bounds: ^Selection_Bounds_2D) {
	if manager == nil {return}
	texture_path, tile_size := tilemap.texture, tilemap.tile_size
	tileset: assets.Tileset_Data
	uses_tileset := tilemap.tileset != ""
	if uses_tileset {
		cached, loaded := manager.tilesets[tilemap.tileset]
		if !loaded {return}
		tileset = cached.data
		texture_path, tile_size = tileset.texture, {f32(tileset.tile_size[0]), f32(tileset.tile_size[1])}
	}
	texture, loaded := manager.textures[texture_path]
	if !loaded || !selection_finite_2d(tile_size) || tile_size[0] <= 0 || tile_size[1] <= 0 {return}
	columns, rows := i32(f32(texture.texture.width)/tile_size[0]), i32(f32(texture.texture.height)/tile_size[1])
	if columns <= 0 || rows <= 0 {return}
	for tile in tilemap.tiles {
		size := tile_size
		if uses_tileset {
			definition, exists := tileset.tiles[tile.index]
			if !exists {continue}
			size *= {f32(definition.size[0]), f32(definition.size[1])}
			if f32(definition.source[0])*tile_size[0]+size[0] > f32(texture.texture.width) ||
			   f32(definition.source[1])*tile_size[1]+size[1] > f32(texture.texture.height) {continue}
		} else if tile.index < 0 || tile.index >= columns*rows {continue}
		position := command.position+[2]f32{f32(tile.x), f32(tile.y)}*tile_size*command.scale
		selection_rectangle_2d(bounds, position, size*command.scale, {}, command.rotation)
	}
}
