package render

import "core:testing"
import "rune:assets"
import "rune:ecs"
import "rune:particles"
import rl "vendor:raylib"

@(test)
scene_pick_2d_matches_draw_order_and_skips_hidden_entities :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	first, second := ecs.create_entity(&w), ecs.create_entity(&w)
	shape := ecs.default_shape_renderer_2d()
	assert(ecs.add(&w, &r, first, shape) && ecs.add(&w, &r, second, shape))
	hit, found := scene_pick_2d(&w, nil, {})
	testing.expect(t, found && hit == second, "equal draw orders choose the later entity as rendering does")
	shape.draw_order = 10
	assert(ecs.set_shape_renderer_2d(&w, first, shape))
	hit, found = scene_pick_2d(&w, nil, {})
	testing.expect(t, found && hit == first, "draw order takes precedence over entity index")
	shape.color.a = 0
	assert(ecs.set_shape_renderer_2d(&w, first, shape))
	hit, found = scene_pick_2d(&w, nil, {})
	testing.expect(t, found && hit == second, "fully transparent shapes do not cover lower objects")
	assert(ecs.set_enabled(&w, second, false))
	_, found = scene_pick_2d(&w, nil, {})
	testing.expect(t, !found, "disabled objects are excluded")
	_, found = scene_pick_2d(&w, nil, {transmute(f32)u32(0x7fc00000), 0})
	testing.expect(t, !found, "nonfinite points never hit")
}

@(test)
scene_pick_2d_matches_hierarchy_inheritance_and_parent_activation :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	parent, child := ecs.create_entity(&w), ecs.create_entity(&w)
	assert(ecs.add(&w, &r, parent, ecs.Transform{position={10,20,0}, scale={2,3,1}, rotation={0,0,90}}))
	assert(ecs.add(&w, &r, child, ecs.Transform{position={4,5,0}, scale={0.5,1,1}}))
	shape := ecs.default_shape_renderer_2d(); shape.origin = {}; shape.size = {10,4}
	assert(ecs.add(&w, &r, child, shape) && ecs.set_parent(&w, child, parent))
	hit, found := scene_pick_2d(&w, nil, {12,40})
	testing.expect(t, found && hit == child, "parent scale applies to offsets while rotation only rotates the visual, matching draw collection")
	_, found = scene_pick_2d(&w, nil, {25,40})
	testing.expect(t, !found, "rotated rectangle excludes its unrotated location")
	assert(ecs.set_enabled(&w, parent, false))
	_, found = scene_pick_2d(&w, nil, {12,40})
	testing.expect(t, !found, "disabling the parent excludes its descendants")
	assert(ecs.set_enabled(&w, parent, true))
	transform, _ := ecs.get_transform(&w, child); transform.scale[0] = 0
	assert(ecs.set_transform(&w, child, transform))
	_, found = scene_pick_2d(&w, nil, {12,40})
	testing.expect(t, !found, "singular visual scale is excluded")
}

@(test)
scene_pick_2d_matches_ellipse_and_unfilled_shape_geometry :: proc(t: ^testing.T) {
	shape := ecs.default_shape_renderer_2d(); shape.shape = .circle; shape.radius = 10
	command := Render_2D_Command{scale={2,1}, rotation=90}
	testing.expect(t, pick_shape_2d(shape, command, {0,18}), "rotated ellipse reaches its major axis")
	testing.expect(t, !pick_shape_2d(shape, command, {9,18}), "ellipse corners do not use rectangular bounds")
	shape.filled = false; shape.line_width = 2
	testing.expect(t, !pick_shape_2d(shape, command, {}), "an outlined ellipse has an empty interior")
	testing.expect(t, pick_shape_2d(shape, command, {0,20.5}), "outline width is measured in world space")
	shape.shape = .rectangle; shape.size = {20,10}
	command.scale = {-2,1}; command.rotation = 0
	testing.expect(t, pick_shape_2d(shape, command, {20.5,0}), "reflected rectangle outline remains pickable")
	testing.expect(t, !pick_shape_2d(shape, command, {}), "outlined rectangle also leaves its interior empty")
}

@(test)
scene_pick_2d_sprite_source_cache_and_signed_rotated_bounds :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	e := ecs.create_entity(&w)
	transform := ecs.Transform{position={100,100,0}, scale={2,1,1}, rotation={0,0,90}}
	sprite := ecs.SpriteRenderer{texture="sprite.png", source={0,0,10,4}, origin={0.5,0.5}, tint={255,255,255,255}}
	assert(ecs.add(&w, &r, e, transform) && ecs.add(&w, &r, e, sprite))
	hit, found := scene_pick_2d(&w, nil, {100,108})
	testing.expect(t, found && hit == e, "explicit sprite source bounds need no asset load")
	_, found = scene_pick_2d(&w, nil, {108,100})
	testing.expect(t, !found, "sprite bounds rotate around its scaled origin")
	transform.rotation = {}; transform.scale = {-2,1,1}; sprite.origin = {}
	assert(ecs.set_transform(&w,e,transform) && ecs.set_sprite_renderer(&w,e,sprite))
	hit, found = scene_pick_2d(&w, nil, {82,102})
	testing.expect(t, found && hit == e, "negative destination dimensions match reflected sprites")
	transform.scale = {1,1,1}; sprite.source = {}
	assert(ecs.set_transform(&w,e,transform) && ecs.set_sprite_renderer(&w,e,sprite))
	manager := assets.Asset_Manager{textures=make(map[string]assets.Texture_Asset), missing_textures=make(map[string]i64)}
	defer delete(manager.textures); defer delete(manager.missing_textures)
	_, found = scene_pick_2d(&w, &manager, {105,105})
	testing.expect(t, !found && len(manager.textures) == 0 && len(manager.missing_textures) == 0, "uncached dimensions skip without asset side effects")
	manager.textures["sprite.png"] = assets.Texture_Asset{texture={width=30,height=10}}
	hit, found = scene_pick_2d(&w, &manager, {125,105})
	testing.expect(t, found && hit == e, "sprites with no source rectangle use cached texture dimensions")
	sprite.tint.a = 0; assert(ecs.set_sprite_renderer(&w,e,sprite))
	_, found = scene_pick_2d(&w, &manager, {125,105})
	testing.expect(t, !found, "fully transparent sprites are excluded")
}

@(test)
scene_pick_2d_tilemaps_hit_occupied_valid_tiles_and_match_tile_rotation :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	e := ecs.create_entity(&w)
	tiles := [3]ecs.Tilemap_Tile{{x=0,y=0,index=1}, {x=2,y=0,index=2}, {x=3,y=0,index=9}}
	indices := make(map[[2]i32]i32); defer delete(indices)
	for tile in tiles {indices[{tile.x,tile.y}] = tile.index}
	tilemap := ecs.TilemapRenderer{texture="tiles.png", tile_size={16,16}, grid_size={4,1}, tiles=tiles[:],tile_indices=indices}
	assert(ecs.add(&w,&r,e,ecs.default_transform()) && ecs.add(&w,&r,e,tilemap))
	manager := assets.Asset_Manager{textures=make(map[string]assets.Texture_Asset)}
	defer delete(manager.textures)
	manager.textures["tiles.png"] = assets.Texture_Asset{texture={width=64,height=32}}
	hit, found := scene_pick_2d(&w,&manager,{40,8})
	testing.expect(t, found && hit == e, "occupied tile is picked")
	_, found = scene_pick_2d(&w,&manager,{24,8})
	testing.expect(t, !found, "sparse map holes are empty")
	_, found = scene_pick_2d(&w,&manager,{56,8})
	testing.expect(t, !found, "undefined atlas tile indices are not rendered or picked")
	transform := ecs.default_transform(); transform.rotation[2] = 90
	assert(ecs.set_transform(&w,e,transform))
	hit, found = scene_pick_2d(&w,&manager,{24,8})
	testing.expect(t, found && hit == e, "each tile rotates at its own grid origin as draw_tile does")
	_, found = scene_pick_2d(&w,&manager,{-8,40})
	testing.expect(t, !found, "map rotation does not rotate grid offsets")
}

@(test)
scene_pick_2d_tilesets_respect_variable_tile_sizes_and_invalid_sources :: proc(t: ^testing.T) {
	definitions := make(map[i32]assets.Tileset_Tile); defer delete(definitions)
	definitions[4] = assets.Tileset_Tile{source={1,0},size={2,1}}
	definitions[5] = assets.Tileset_Tile{source={3,0},size={2,1}}
	manager := assets.Asset_Manager{textures=make(map[string]assets.Texture_Asset),tilesets=make(map[string]assets.Tileset_Asset)}
	defer delete(manager.textures); defer delete(manager.tilesets)
	manager.textures["tiles.png"] = assets.Texture_Asset{texture={width=64,height=32}}
	manager.tilesets["tiles.json"] = assets.Tileset_Asset{data={texture="tiles.png",tile_size={16,16},tiles=definitions}}
	tiles := [2]ecs.Tilemap_Tile{{x=0,y=0,index=4},{x=4,y=0,index=5}}
	tilemap := ecs.TilemapRenderer{tileset="tiles.json",tiles=tiles[:]}
	command := Render_2D_Command{scale={1,1}}
	testing.expect(t, pick_tilemap_2d(&manager,tilemap,command,{24,8}), "variable-size tile extends beyond its occupied cell")
	testing.expect(t, !pick_tilemap_2d(&manager,tilemap,command,{72,8}), "tile whose source exceeds texture bounds is excluded")
	testing.expect(t, len(manager.textures)==1 && len(manager.tilesets)==1 && len(manager.diagnostics.pending)==0, "picking does not load assets or report diagnostics")
}

@(test)
scene_pick_2d_text_uses_cached_font_and_rendered_text_scale :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	e := ecs.create_entity(&w)
	assert(ecs.add(&w,&r,e,ecs.Transform{position={100,100,0},rotation={0,0,90},scale={1,8,1}}))
	assert(ecs.add(&w,&r,e,ecs.TextRenderer{text="A",font="font.ttf",font_size=20,origin={0.5,0.5},color={255,255,255,255}}))
	manager := assets.Asset_Manager{fonts=make(map[string]assets.Font_Asset)}; defer delete(manager.fonts)
	_, found := scene_pick_2d(&w,&manager,{109,100})
	testing.expect(t, !found, "uncached fonts are skipped without loading")
	glyphs := [2]rl.GlyphInfo{{value=63,advanceX=6},{value=65,advanceX=6}}
	recs := [2]rl.Rectangle{{width=6,height=10},{width=6,height=10}}
	manager.fonts["font.ttf"] = assets.Font_Asset{font={baseSize=10,glyphCount=2,texture={id=1},glyphs=raw_data(glyphs[:]),recs=raw_data(recs[:])}}
	hit: ecs.Entity
	hit, found = scene_pick_2d(&w,&manager,{109,100})
	testing.expect(t, found && hit == e, "cached CPU font metrics support rotated text bounds without a window")
	_, found = scene_pick_2d(&w,&manager,{100,109})
	testing.expect(t, !found, "text uses X scale for both axes, matching draw_text")
}

@(test)
scene_pick_2d_particles_use_live_world_positions :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	e := ecs.create_entity(&w)
	assert(ecs.add(&w,&r,e,ecs.Transform{position={500,500,0},scale={1,1,1}}))
	assert(ecs.add(&w,&r,e,ecs.default_particle_emitter_2d()))
	state := particles.State{particles=make([dynamic]particles.Particle2D)}
	append(&state.particles,particles.Particle2D{position={20,30},lifetime=1,start_size=10,end_size=10,start_color={255,255,255,255},end_color={255,255,255,255}})
	w.particle_states_2d[e] = state
	hit, found := scene_pick_2d(&w,nil,{20,30})
	testing.expect(t, found && hit == e, "particles already store world positions and do not inherit emitter transforms")
	_, found = scene_pick_2d(&w,nil,{24,34})
	testing.expect(t, !found, "untextured particles use circular bounds")
}
