package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

render_frame :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	assert(bridge.draw_scene(ctx,w,manager))
	rl.EndDrawing()
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(640,360,"Terrain GPU validation")
	defer rl.CloseWindow()
	manager := assets.init(".")
	defer assets.shutdown(&manager)
	ctx,ready := bridge.init(".",640,360); assert(ready)
	defer bridge.shutdown(&ctx)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w := ecs.init(); defer ecs.destroy(&w)
	camera := ecs.create_entity(&w)
	assert(add_transform(&w,&r,camera,{position={20,16,24},scale={1,1,1}}))
	assert(ecs.add_component(&w,&r,camera,"Camera3D",parse(`{"active":true,"target":[8,2,8]}`)))
	e := ecs.create_entity(&w)
	assert(add_transform(&w,&r,e,{scale={1,1,1}}))
	t := ecs.default_terrain(); t.asset="build/terrain-test.terrain.json"
	assert(ecs.add(&w,&r,e,t))
	ecs.sync_terrains(&w,&manager)
	render_frame(&ctx,&w,&manager)
	cache,found := ctx.terrains[e]
	assert(found && len(cache.chunks)==4,"four terrain render chunks")
	indices:i32
	for mesh in cache.chunks {indices += mesh.indexCount}
	assert(indices==16*16*6,"all terrain cells uploaded once")
	initial := cache.revision
	assert(write_fixture("build/terrain-test.terrain.json",`{"heightmap":"build/terrain-test.r16","resolution":[17,17],"size":[16,16],"height_scale":16,"height_offset":4,"chunk_cells":16}`)==nil)
	assets.refresh_terrains(&manager)
	ecs.sync_terrains(&w,&manager)
	render_frame(&ctx,&w,&manager)
	cache=ctx.terrains[e]
	assert(cache.revision>initial && len(cache.chunks)==1,"successful reload replaces GPU chunks")
	initial=cache.revision
	assert(write_fixture("build/terrain-test.terrain.json","invalid")==nil)
	assets.refresh_terrains(&manager)
	ecs.sync_terrains(&w,&manager)
	render_frame(&ctx,&w,&manager)
	assert(ctx.terrains[e].revision==initial,"invalid reload keeps GPU chunks")
	assert(ecs.remove_component(&w,e,"Terrain"))
	render_frame(&ctx,&w,&manager)
	assert(len(ctx.terrains)==0,"removed terrain releases GPU cache")
	// Restore descriptor; a missing/invalid first asset can recover too.
	assert(write_fixture("build/terrain-test.terrain.json",`{"heightmap":"build/terrain-test.r16","resolution":[17,17],"size":[16,16],"height_scale":16,"chunk_cells":8}`)==nil)
	assets.refresh_terrains(&manager)
	assert(len(manager.diagnostics.reported)==0,"repair clears diagnostics even when failed descriptor had no heightmap path")
	assert(ecs.add(&w,&r,e,t)); ecs.sync_terrains(&w,&manager)
	render_frame(&ctx,&w,&manager)
	other := ecs.init(); defer ecs.destroy(&other)
	rl.BeginDrawing()
	bridge.draw_scene(&ctx,&other,&manager)
	rl.EndDrawing()
	assert(len(ctx.terrains)==0,"world generation clears terrain GPU cache")
	fmt.println("PASS runtime terrain drawing, GPU topology, valid/invalid reloads, removal and scene replacement")
}
