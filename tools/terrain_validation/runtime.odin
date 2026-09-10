package main

import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

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
	validate_blend_runtime(&ctx,&manager,&r)
}

validate_blend_runtime :: proc(ctx:^bridge.Context,manager:^assets.Asset_Manager,r:^ecs.Component_Registry) {
	// Solid primary colors make layer selection and mixing observable in pixels.
	paths := [3]string{"build/terrain-grass.png","build/terrain-dirt.png","build/terrain-rock.png"}
	colors := [3]rl.Color{{255,0,0,255},{0,255,0,255},{0,0,255,255}}
	for path,i in paths {
		image := rl.GenImageColor(4,4,colors[i])
		assert(rl.ExportImage(image,strings.clone_to_cstring(path,context.temp_allocator)))
		rl.UnloadImage(image)
	}
	assert(write_fixture("build/terrain-blend.material.json",`{"base_color":[255,255,255,255],"lighting":false}`)==nil)
	d := terrain.default_description()
	d.heightmap="build/terrain-test.r16"; d.resolution={17,17}; d.size={16,16}; d.height_scale=0
	d.material="build/terrain-blend.material.json"
	d.blend.grass,d.blend.dirt,d.blend.rock=paths[0],paths[1],paths[2]
	d.blend.dirt_height={-2,-1}; d.blend.rock_slope={60,80}; d.blend.noise_strength=0
	path := "build/terrain-blend-runtime.terrain.json"
	bytes,_ := json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	w := ecs.init(); defer ecs.destroy(&w)
	camera := ecs.create_entity(&w)
	assert(add_transform(&w,r,camera,{position={8,30,8},scale={1,1,1}}))
	assert(ecs.add_component(&w,r,camera,"Camera3D",parse(`{"active":true,"target":[8,0,8],"up":[0,0,-1],"fovy":40}`)))
	e := ecs.create_entity(&w)
	assert(add_transform(&w,r,e,{scale={1,1,1}}))
	t := ecs.default_terrain(); t.asset=path
	assert(ecs.add(&w,r,e,t))
	ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].blend_shader!=nil,"blend surface shader compiles")
	pixel := blend_center_pixel(ctx,&w,manager)
	assert(pixel.r>150 && pixel.g<30 && pixel.b<30,"high flat ground selects grass")
	for heights,index in ([2][2]f32{{-1,1},{1,2}}) {
		d.blend.dirt_height=heights
		bytes,_ = json.marshal(d,allocator=context.temp_allocator)
		assert(write_fixture(path,bytes)==nil)
		assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
		render_frame(ctx,&w,manager)
		pixel=blend_center_pixel(ctx,&w,manager)
		if index==0 {assert(pixel.r>70 && pixel.g>70 && pixel.b<30,"transition mixes grass and dirt")}
		else {assert(pixel.g>150 && pixel.r<30 && pixel.b<30,"low ground selects dirt after reload")}
	}
	d.blend.dirt_height={-1,1}; d.blend.noise_strength=0.8
	bytes,_ = json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	blend_center_pixel(ctx,&w,manager,check_noise=true)
	d.blend.noise_strength=0
	// A tilted heightfield must select rock without changing collision topology.
	d.height_scale=16; d.blend.rock_slope={1,2}
	bytes,_ = json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(pixel.b>150 && pixel.r<30 && pixel.g<30,"steep ground selects rock")
	// A second terrain must not share mutable uniform/sampler state.
	other := ecs.create_entity(&w)
	assert(add_transform(&w,r,other,{position={20,0,0},scale={1,1,1}}))
	assert(ecs.add(&w,r,other,t)); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].blend_shader!=ctx.terrains[other].blend_shader,"independent per-entity shader state")
	// Invalid descriptor retains the already-rendered blend; disabling releases it.
	old := ctx.terrains[e].blend_shader
	assert(write_fixture(path,`{"blend":{"rock_slope":[30,10]}}`)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].blend_shader==old,"bad reload retains blend shader")
	d.blend=terrain.default_blend()
	bytes,_ = json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].blend_shader==nil,"disabling blend releases shader")
	assert(ecs.destroy_entity(&w,e) && ecs.destroy_entity(&w,other))
	render_frame(ctx,&w,manager)
	assert(len(ctx.terrains)==0,"removal releases blended terrain caches")
	fmt.println("PASS runtime blend pixels, continuous noise, slope, independent shaders, reload retention and cleanup")
}

blend_center_pixel :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,check_noise:=false) -> rl.Color {
	rl.BeginDrawing()
	defer rl.EndDrawing()
	assert(bridge.draw_scene(ctx,w,manager))
	rlgl.DrawRenderBatchActive()
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)
	if check_noise {
		min_red,max_red := 255,0
		for y := image.height/2-64; y<image.height/2+64; y+=1 {
			for x := image.width/2-64; x<image.width/2+64; x+=1 {
				p := rl.GetImageColor(image,x,y)
				min_red,max_red=min(min_red,int(p.r)),max(max_red,int(p.r))
				for offset in ([2][2]i32{{1,0},{0,1}}) {
					n := rl.GetImageColor(image,x+offset[0],y+offset[1])
					assert(abs(int(p.r)-int(n.r))<30 && abs(int(p.g)-int(n.g))<30,"noise remains continuous across lattice boundaries")
				}
			}
		}
		assert(max_red-min_red>8,"noise visibly varies the blend")
	}
	return rl.GetImageColor(image,image.width/2,image.height/2)
}
