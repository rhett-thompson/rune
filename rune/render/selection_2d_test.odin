package render

import "core:math"
import "core:testing"
import "rune:assets"
import "rune:ecs"
import "rune:particles"
import rl "vendor:raylib"

@(private)
expect_selection_rectangle_2d :: proc(t: ^testing.T, got, expected: rl.Rectangle) {
	testing.expect(t, math.abs(got.x-expected.x)<0.001 && math.abs(got.y-expected.y)<0.001 &&
		math.abs(got.width-expected.width)<0.001 && math.abs(got.height-expected.height)<0.001,
		"selection bounds match the rendered geometry and camera")
}

@(test)
selection_2d_projects_hierarchy_and_mirrored_outline_through_camera :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	parent, child := ecs.create_entity(&w), ecs.create_entity(&w)
	assert(ecs.add(&w,&r,parent,ecs.Transform{position={10,20,0},scale={2,3,1},rotation={0,0,90}}))
	assert(ecs.add(&w,&r,child,ecs.Transform{position={4,5,0},scale={-0.5,1,1}}))
	shape := ecs.default_shape_renderer_2d(); shape.origin={}; shape.size={10,4}; shape.filled=false; shape.line_width=2
	assert(ecs.add(&w,&r,child,shape) && ecs.set_parent(&w,child,parent))
	camera := rl.Camera2D{target={10,20},offset={100,200},zoom=2}
	bounds, found := scene_selection_bounds_2d(&w,nil,child,camera)
	testing.expect(t,found,"enabled child has rendered bounds")
	// The draw hierarchy places the child at (18,35), with signed size (-10,12)
	// rotated 90 degrees. Its world-space 2px miter expands each side by one.
	expect_selection_rectangle_2d(t,bounds,{90,208,28,24})
	camera.rotation=90
	bounds, found=scene_selection_bounds_2d(&w,nil,child,camera)
	testing.expect(t,found)
	expect_selection_rectangle_2d(t,bounds,{68,190,24,28})
	camera.zoom=-2
	bounds, found=scene_selection_bounds_2d(&w,nil,child,camera)
	testing.expect(t,found,"negative camera zoom remains a valid reflected camera")
	expect_selection_rectangle_2d(t,bounds,{108,182,24,28})
	assert(ecs.set_enabled(&w,parent,false))
	_, found=scene_selection_bounds_2d(&w,nil,child,camera)
	testing.expect(t,!found,"ancestor activation matches the draw collector")
}

@(test)
selection_2d_unions_entity_components_without_children_and_tracks_edits :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	entity, child := ecs.create_entity(&w), ecs.create_entity(&w)
	shape := ecs.default_shape_renderer_2d(); shape.origin={}; shape.size={10,4}
	sprite := ecs.SpriteRenderer{source={0,0,20,8},origin={0.5,0.5},tint={255,255,255,255}}
	assert(ecs.add(&w,&r,entity,shape) && ecs.add(&w,&r,entity,sprite))
	assert(ecs.add(&w,&r,entity,ecs.Transform{position={50,80,0},scale={1,1,1}}))
	assert(ecs.add(&w,&r,child,ecs.Transform{position={500,500,0},scale={1,1,1}}))
	assert(ecs.add(&w,&r,child,shape) && ecs.set_parent(&w,child,entity))
	camera := rl.Camera2D{zoom=1}
	bounds, found := scene_selection_bounds_2d(&w,nil,entity,camera)
	testing.expect(t,found)
	expect_selection_rectangle_2d(t,bounds,{40,76,20,8})
	transform,_:=ecs.get_transform(&w,entity); transform.position={100,120,0}; transform.rotation[2]=90
	assert(ecs.set_transform(&w,entity,transform))
	bounds, found=scene_selection_bounds_2d(&w,nil,entity,camera)
	testing.expect(t,found)
	expect_selection_rectangle_2d(t,bounds,{96,110,8,20})
	shape.color.a=0; sprite.tint.a=0
	assert(ecs.set_shape_renderer_2d(&w,entity,shape) && ecs.set_sprite_renderer(&w,entity,sprite))
	_, found=scene_selection_bounds_2d(&w,nil,entity,camera)
	testing.expect(t,!found,"transparent components do not retain an old highlight")
}

@(test)
selection_2d_cached_sprite_and_text_dimensions_do_not_load_assets :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,entity,ecs.SpriteRenderer{texture="sprite.png",tint={255,255,255,255}}))
	manager:=assets.Asset_Manager{textures=make(map[string]assets.Texture_Asset),fonts=make(map[string]assets.Font_Asset),missing_textures=make(map[string]i64)}
	defer delete(manager.textures); defer delete(manager.fonts); defer delete(manager.missing_textures)
	camera:=rl.Camera2D{zoom=1}
	_, found:=scene_selection_bounds_2d(&w,&manager,entity,camera)
	testing.expect(t,!found && len(manager.textures)==0 && len(manager.missing_textures)==0 && len(manager.diagnostics.pending)==0,"uncached data is skipped without cache or diagnostic mutation")
	manager.textures["sprite.png"]=assets.Texture_Asset{texture={width=30,height=10}}
	bounds:rl.Rectangle
	bounds, found=scene_selection_bounds_2d(&w,&manager,entity,camera)
	testing.expect(t,found); expect_selection_rectangle_2d(t,bounds,{0,0,30,10})
	assert(ecs.add(&w,&r,entity,ecs.TextRenderer{text="A",font="font.ttf",font_size=20,origin={0.5,0.5},color={255,255,255,255}}))
	glyphs:=[2]rl.GlyphInfo{{value=63,advanceX=6},{value=65,advanceX=6}}
	recs:=[2]rl.Rectangle{{width=6,height=10},{width=6,height=10}}
	manager.fonts["font.ttf"]=assets.Font_Asset{font={baseSize=10,glyphCount=2,texture={id=1},glyphs=raw_data(glyphs[:]),recs=raw_data(recs[:])}}
	bounds, found=scene_selection_bounds_2d(&w,&manager,entity,camera)
	testing.expect(t,found); expect_selection_rectangle_2d(t,bounds,{-6,-10,36,20})
	testing.expect(t,len(manager.textures)==1 && len(manager.fonts)==1 && len(manager.diagnostics.pending)==0,"cached metrics remain read only")
}

@(test)
selection_2d_tile_bounds_use_only_valid_occupied_tiles :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	entity:=ecs.create_entity(&w)
	definitions:=make(map[i32]assets.Tileset_Tile); defer delete(definitions)
	definitions[4]=assets.Tileset_Tile{source={1,0},size={2,1}}
	definitions[5]=assets.Tileset_Tile{source={3,0},size={2,1}}
	manager:=assets.Asset_Manager{textures=make(map[string]assets.Texture_Asset),tilesets=make(map[string]assets.Tileset_Asset)}
	defer delete(manager.textures); defer delete(manager.tilesets)
	manager.textures["tiles.png"]=assets.Texture_Asset{texture={width=64,height=32}}
	manager.tilesets["tiles.json"]=assets.Tileset_Asset{data={texture="tiles.png",tile_size={16,16},tiles=definitions}}
	tiles:=[3]ecs.Tilemap_Tile{{x=0,y=0,index=4},{x=4,y=0,index=5},{x=20,y=20,index=99}}
	indices:=make(map[[2]i32]i32); defer delete(indices)
	for tile in tiles {indices[{tile.x,tile.y}]=tile.index}
	assert(ecs.add(&w,&r,entity,ecs.TilemapRenderer{tileset="tiles.json",tiles=tiles[:],tile_indices=indices,grid_size={21,21}}))
	assert(ecs.add(&w,&r,entity,ecs.Transform{position={10,20,0},scale={-2,1,1},rotation={0,0,90}}))
	bounds,found:=scene_selection_bounds_2d(&w,&manager,entity,rl.Camera2D{zoom=1})
	testing.expect(t,found); expect_selection_rectangle_2d(t,bounds,{-6,-44,16,64})
	testing.expect(t,len(manager.diagnostics.pending)==0,"invalid tiles do not generate diagnostics during selection")
}

@(test)
selection_2d_live_particles_ignore_emitter_transform_and_track_expiration :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,entity,ecs.Transform{position={500,500,0},scale={4,4,1},rotation={0,0,40}}))
	assert(ecs.add(&w,&r,entity,ecs.default_particle_emitter_2d()))
	state:=particles.State{particles=make([dynamic]particles.Particle2D)}
	append(&state.particles,particles.Particle2D{position={20,30},lifetime=1,start_size=10,end_size=10,start_color={255,255,255,255},end_color={255,255,255,255}})
	w.particle_states_2d[entity]=state
	camera:=rl.Camera2D{rotation=90,zoom=2}
	bounds,found:=scene_selection_bounds_2d(&w,nil,entity,camera)
	testing.expect(t,found); expect_selection_rectangle_2d(t,bounds,{-70,30,20,20})
	w.particle_states_2d[entity].particles[0].start_color[3]=0
	w.particle_states_2d[entity].particles[0].end_color[3]=0
	_,found=scene_selection_bounds_2d(&w,nil,entity,camera)
	testing.expect(t,!found,"no stale bounds remain when no visible particles remain")
}

@(test)
selection_2d_invalid_inputs_and_degenerate_visuals_have_no_bounds :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,entity,ecs.default_shape_renderer_2d()))
	camera:=rl.Camera2D{zoom=1}
	_,found:=scene_selection_bounds_2d(nil,nil,entity,camera); testing.expect(t,!found)
	_,found=scene_selection_bounds_2d(&w,nil,0,camera); testing.expect(t,!found)
	camera.target.x=transmute(f32)u32(0x7fc00000)
	_,found=scene_selection_bounds_2d(&w,nil,entity,camera); testing.expect(t,!found)
	camera=rl.Camera2D{zoom=0}
	_,found=scene_selection_bounds_2d(&w,nil,entity,camera); testing.expect(t,!found)
	assert(ecs.add(&w,&r,entity,ecs.Transform{scale={0,1,1}}))
	_,found=scene_selection_bounds_2d(&w,nil,entity,rl.Camera2D{zoom=1}); testing.expect(t,!found)
}
