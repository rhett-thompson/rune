package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

validate_surface_filters :: proc() {
	Descriptor :: "build/terrain-surface-parse.terrain.json"
	prefix := `{"heightmap":"tools/terrain_validation/fixtures/precision.png","resolution":[2,2],`
	for fields in ([]string{
		`"layers":[{"material":"x","surface":12}]`,
		`"layers":[{"material":"x","weight_source":"automatic"}]`,
		`"layers":[{"material":"x","weight_source":false}]`,
		`"layers":[{"material":"x","surface":"grass"}],"details":[{"surface":"Grass","surface_min":0.5}]`,
		`"layers":[{"material":"x","name":"grass"}],"details":[{"surface":"grass","surface_min":0.5}]`,
		`"details":[{"surface_min":0.5}]`,
		`"details":[{"surface":"grass","surface_min":1.01}]`,
		`"details":[{"surface":"grass","surface_min":-0.01}]`,
		`"details":[{"surface":"grass","surface_min":"0.5"}]`,
	}) {
		assert(write_fixture(Descriptor,fmt.tprint(prefix,fields,"}"))==nil)
		data,_,error := terrain.load(".",Descriptor)
		defer terrain.destroy(&data)
		assert(error!="",fmt.tprint("reject invalid terrain surface settings: ",fields))
	}
	assert(write_fixture(Descriptor,fmt.tprint(prefix,`
		"layers":[{"name":"Primary","material":"one","surface":"Tall Grass","weight_source":"default"},
		          {"name":"Secondary","material":"two","surface":"Tall Grass","weight_source":"paint_and_bands"}],
		"details":[{"surface":"Tall Grass","surface_min":0.5},{"surface":"unused"}]}`))==nil)
	loaded,_,error := terrain.load(".",Descriptor)
	assert(error=="",error)
	cloned := terrain.clone(loaded)
	assert(raw_data(cloned.description.layers[0].surface)!=raw_data(loaded.description.layers[0].surface))
	assert(raw_data(cloned.description.layers[1].weight_source)!=raw_data(loaded.description.layers[1].weight_source))
	assert(raw_data(cloned.description.details[0].surface)!=raw_data(loaded.description.details[0].surface))
	terrain.destroy(&loaded)
	assert(cloned.description.layers[0].surface=="Tall Grass" && cloned.description.layers[1].surface=="Tall Grass")
	assert(cloned.description.layers[1].weight_source=="paint_and_bands")
	assert(cloned.description.details[0].surface=="Tall Grass" && cloned.description.details[0].surface_min==0.5)
	assert(cloned.description.details[1].surface_min==0,"an omitted threshold disables the filter")
	terrain.destroy(&cloned)

	validate_surface_weights()
	fmt.println("PASS terrain surface filter parsing, ownership, sampling and deterministic scatter")
}

validate_surface_weights :: proc() {
	description := terrain.default_description()
	description.resolution = {3,2}
	description.size = {2,1}
	description.control_maps = {"control-a.png","control-b.png"}
	layers: [5]terrain.Layer
	for &layer in layers {layer=terrain.default_layer()}
	layers[0].surface, layers[0].weight = "grass",2
	layers[1].surface, layers[1].weight_source = "dirt","bands"
	layers[2].surface, layers[2].weight_source = "moss","paint_and_bands"
	layers[2].height = {-1,1,2,3}
	layers[3].weight = 0
	layers[4].surface = "grass"
	description.layers = layers[:]
	heights: [6]f32
	data := terrain.Data{description=description,heights=heights[:]}
	// Both groups have two texels. Layer 1 ignores G, which is zero throughout.
	pixels := [16]u8{255,0,255,0, 0,0,0,0, 255,0,0,0, 0,0,0,0}
	controls := terrain.Control_Map{width=2,height=1,pixels=pixels[:]}
	weights,ready := terrain.layer_weights(data,1,0.5,&controls)
	assert(ready)
	for expected,i in ([5]f32{4.0/11,4.0/11,1.0/11,0,2.0/11}) {
		assert(math.abs(weights[i]-expected)<0.00001,"blend normalizes paint, automatic bands and their product")
	}
	weight,found := terrain.surface_weight(data,1,0.5,"grass",&controls)
	assert(found && math.abs(weight-6.0/11)<0.00001,"same surface tags aggregate across both RGBA maps")
	_,found = terrain.surface_weight(data,1,0.5,"Grass",&controls)
	assert(!found,"surface tags match exactly")
	_,found = terrain.surface_weight(data,-0.01,0.5,"grass",&controls)
	assert(!found,"off-terrain samples are unavailable")
	_,found = terrain.surface_weight(data,1,0.5,"grass")
	assert(!found,"paint-dependent samples are unavailable without their mask")

	rule := terrain.default_detail("rock")
	rule.count,rule.seed = 64,41
	unfiltered := terrain.scatter_details(data,rule)
	defer delete(unfiltered)
	rule.surface,rule.surface_min = "grass",0.5
	filtered := terrain.scatter_details(data,rule,&controls)
	defer delete(filtered)
	assert(len(filtered)>0 && len(filtered)<len(unfiltered))
	accepted := 0
	for candidate in unfiltered {
		weight,ready = terrain.surface_weight(data,candidate.position[0],candidate.position[2],rule.surface,&controls)
		assert(ready)
		if weight<rule.surface_min {continue}
		assert(accepted<len(filtered) && filtered[accepted]==candidate,"filter preserves deterministic order and poses")
		accepted += 1
	}
	assert(accepted==len(filtered))
	missing := terrain.scatter_details(data,rule)
	defer delete(missing)
	assert(len(missing)==0,"paint-dependent detail rules fail closed without the mask")

	// A flat facet next to a ramp has a tilted renderer normal near the seam.
	heights = {0,0,1,0,0,1}
	data.description.layers = layers[:2]
	layers[0].weight_source = "bands"
	layers[0].slope = {-1,0,10,10}
	assert(terrain.sample_surface_normal(data,0.5,0.25)[1]==1)
	weights,ready = terrain.layer_weights(data,0.5,0.25)
	assert(ready && weights[0]==0 && weights[1]==1,"bands follow interpolated vertex slope rather than facet slope")
	weights,ready = terrain.layer_weights(data,0.125,0.25)
	assert(ready && math.abs(weights[0]-2.0/3)<0.00001,"bands still admit the gentle part of the facet")
	// The unpacked interpolated normal tilts about 13.283 degrees. R3D's
	// packed vertex normals yield about 13.307 degrees at the same point.
	layers[0].slope = {13.295,13.295,90,91}
	weights,ready = terrain.layer_weights(data,0.5,0.25)
	assert(ready && math.abs(weights[0]-2.0/3)<0.00001,"hard slope cutoffs use the decoded vertex attributes")
	layers[0].slope = {-1,0,10,10}
	layers[1].weight = 0
	weights,ready = terrain.layer_weights(data,0.5,0.25)
	assert(ready && weights[0]==1 && weights[1]==0,"an empty blend falls back to layer zero")
	layers[1].weight = 0.000001
	weights,ready = terrain.layer_weights(data,0.5,0.25)
	assert(ready && weights[0]==1 && weights[1]==layers[1].weight,"tiny totals retain the shader's legacy layer-zero fallback")
}

write_surface_map :: proc(path: string, color: rl.Color) {
	image := rl.GenImageColor(1,1,color)
	defer rl.UnloadImage(image)
	byte_count: i32
	bytes := rl.ExportImageToMemory(image,".png",&byte_count)
	assert(bytes!=nil && byte_count>0)
	defer rl.MemFree(bytes)
	assert(write_fixture(path,([^]u8)(bytes)[:byte_count])==nil)
}

validate_surface_filter_rendering :: proc(ctx: ^bridge.Context, registry: ^ecs.Component_Registry) {
	Descriptor :: "build/terrain-filter-surface.terrain.json"
	Heightmap :: "build/terrain-filter-surface.r16"
	Control :: "build/terrain-filter-surface.png"
	Base_Material :: "build/terrain-filter-base.material.json"
	assert(write_fixture(Base_Material,`{"base_color":[255,255,255,255],"lighting":true}`)==nil)
	materials := [3]string{"build/terrain-filter-grass.material.json","build/terrain-filter-dirt.material.json","build/terrain-filter-moss.material.json"}
	colors := [3]rl.Color{{255,0,0,255},{0,255,0,255},{0,0,255,255}}
	for path,i in materials {write_layer_fixture(path,colors[i],roughness=0.5,metallic=0)}
	heights: [17*17*2]u8
	assert(write_fixture(Heightmap,heights[:])==nil)
	write_surface_map(Control,{255,0,255,0})

	description := terrain.default_description()
	description.heightmap,description.resolution,description.size = Heightmap,{17,17},{16,16}
	description.material = Base_Material
	description.chunk_cells = 8
	description.control_maps = {Control}
	layers: [3]terrain.Layer
	for &layer,i in layers {
		layer = terrain.default_layer()
		layer.material = materials[i]
	}
	layers[0].surface,layers[0].weight_source,layers[0].weight = "grass","default",2
	layers[1].surface,layers[1].weight_source,layers[1].height = "dirt","bands",{-1,-1,1,1}
	layers[2].surface,layers[2].weight_source,layers[2].height = "moss","paint_and_bands",{-1,1,2,3}
	description.layers = layers[:]
	bytes,error := json.marshal(description,allocator=context.temp_allocator)
	assert(error==nil && write_fixture(Descriptor,bytes)==nil)
	manager := assets.init(".")
	defer assets.shutdown(&manager)
	if ctx.worker_pool!=nil {assert(assets.configure_asset_jobs(&manager,ctx.worker_pool))}
	w := ecs.init()
	defer ecs.destroy(&w)
	e := add_region_terrain(&w,registry,Descriptor,40)
	camera := ecs.create_entity(&w)
	assert(add_transform(&w,registry,camera,{position={48,25,8},scale={1,1,1}}))
	assert(ecs.add_component(&w,registry,camera,"Camera3D",parse(`{"active":true,"target":[48,0,8],"up":[0,0,-1],"fovy":35}`)))
	ecs.sync_terrains(&w,&manager)
	r3d.SetOutputMode(.ALBEDO)
	defer r3d.SetOutputMode(.SCENE)
	pixel := blend_center_pixel(ctx,&w,&manager)
	weights := [3]f32{4.0/7,2.0/7,1.0/7}
	for surface,i in ([3]string{"grass","dirt","moss"}) {
		weight,found := bridge.terrain_surface_weight(ctx,&w,e,{48,0,8},surface)
		assert(found && math.abs(weight-weights[i])<0.00001,"world-space query matches CPU blend")
	}
	assert(abs(int(pixel.r)-146)<=2 && abs(int(pixel.g)-73)<=2 && abs(int(pixel.b)-36)<=2,
		fmt.tprintf("shader blends painted, band-driven and combined weights: %v",pixel))
	_,inside := bridge.terrain_surface_weight(ctx,&w,e,{8,0,8},"grass")
	assert(!inside,"world coordinates account for the translated terrain")
	assert(ecs.update_terrain_region(&w,e,8,8,9,9,{4}))
	weight,found := bridge.terrain_surface_weight(ctx,&w,e,{48,0,8},"grass")
	assert(found && math.abs(weight-weights[0])<0.00001,"surface queries use committed heights during a preview")
	assert(ecs.commit_terrain_region(&w,e))
	weight,found = bridge.terrain_surface_weight(ctx,&w,e,{48,4,8},"grass")
	assert(found && weight==1,"surface queries use the new heights after commit")

	validate_surface_filter_reload(ctx,&manager,&w,e,description,Descriptor)
	fmt.println("PASS rendered paint and band weights, surface queries, and selective filtered detail reload")
}

validate_surface_filter_reload :: proc(ctx: ^bridge.Context, manager: ^assets.Asset_Manager, w: ^ecs.World,
		e: ecs.Entity, description: terrain.Description, descriptor: string) {
	description := description
	Missing_Control :: "build/terrain-filter-missing.png"
	// Make this assertion repeatable after a previous run repaired the fixture.
	if os.is_file(Missing_Control) {assert(os.remove(Missing_Control)==nil)}
	description.control_maps = {Missing_Control}
	rules := [2]terrain.Detail{terrain.default_detail("rock"),terrain.default_detail("rock")}
	for &rule in rules {rule.count=64; rule.draw_distance=1}
	rules[0].surface,rules[0].surface_min = "grass",0.5
	description.details = rules[:]
	bytes,error := json.marshal(description,allocator=context.temp_allocator)
	assert(error==nil && write_fixture(descriptor,bytes)==nil)
	assets.refresh_terrains(manager)
	ecs.sync_terrains(w,manager)
	render_frame(ctx,w,manager)
	assert(raycast_region_height(w,e,48,8)==0)
	body := w.box3d_bodies[e]
	cache := ctx.terrains[e]
	assert(len(cache.chunks)==4 && len(cache.details)==2)
	assert(len(cache.details[0].instances)==0 && len(cache.details[1].instances)==64,"missing initial paint suppresses only filtered detail")
	_,available := bridge.terrain_surface_weight(ctx,w,e,{48,0,8},"grass")
	assert(!available,"no committed mask is available yet")
	geometry: [4][2]i32
	for mesh,i in cache.chunks {geometry[i]={mesh.vertexOffset,mesh.indexOffset}}
	unfiltered := cache.details[1].buffer.buffers[0]
	write_surface_map(Missing_Control,{255,0,255,0})
	refresh_surface_map(manager)
	render_frame(ctx,w,manager)
	cache = ctx.terrains[e]
	assert(len(cache.details[0].instances)==64 && len(cache.details[1].instances)==64)
	assert(cache.details[1].buffer.buffers[0]==unfiltered && ctx.frame_stats.terrain_chunks_built==0)
	filtered := cache.details[0].buffer.buffers[0]
	assert(unfiltered!=0 && filtered!=0)
	paint := cache.layer_set.paint.texture.id
	atlas := cache.layer_set.atlases[0].id

	assert(write_fixture(Missing_Control,"invalid image")==nil)
	refresh_surface_map(manager)
	render_frame(ctx,w,manager)
	cache = ctx.terrains[e]
	assert(cache.layer_set.paint.texture.id==paint && cache.details[0].buffer.buffers[0]==filtered,
		"an invalid mask retains the current atlas and detail batch")
	write_surface_map(Missing_Control,{0,0,0,0})
	refresh_surface_map(manager)
	// Both polling paths can run during the same frame, as in the scene loop.
	assets.refresh_terrains(manager)
	ecs.sync_terrains(w,manager)
	pixel := blend_center_pixel(ctx,w,manager)
	assert(pixel==rl.Color{0,255,0,255},"a zero paint channel suppresses the gated layer while automatic bands persist")
	cache = ctx.terrains[e]
	assert(cache.layer_set.paint.texture.id!=paint && cache.layer_set.atlases[0].id==atlas,
		"a paint edit replaces its atlas and retains material textures")
	assert(len(cache.details[0].instances)==0 && cache.details[1].buffer.buffers[0]==unfiltered,
		"a paint edit refreshes only filtered detail batches")
	assert(ctx.frame_stats.terrain_chunks_built==0 && raycast_region_height(w,e,48,8)==0 && w.box3d_bodies[e]==body,
		"a paint edit preserves collision and terrain geometry")
	for mesh,i in cache.chunks {
		assert(geometry[i]==[2]i32{mesh.vertexOffset,mesh.indexOffset},"paint edits retain installed GPU mesh allocations")
	}
	weight,found := bridge.terrain_surface_weight(ctx,w,e,{48,0,8},"grass")
	assert(found && weight==0,"query follows the published mask after reload")
}

refresh_surface_map :: proc(manager: ^assets.Asset_Manager) {
	assets.refresh_background(manager)
	if manager.texture_reloads!=nil {
		assert(assets.texture_reload_stats(manager).in_flight==1,"queue the edited control map for background replacement")
	}
	started := time.tick_now()
	for assets.texture_reload_stats(manager).in_flight>0 {
		assert(time.tick_since(started)<5*time.Second,"control-map texture reload timed out")
		assets.pump_asset_jobs(manager)
		time.sleep(time.Millisecond)
	}
}
