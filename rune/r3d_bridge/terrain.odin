package r3d_bridge

import "core:mem"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Terrain_Cache :: struct {
	revision, source_revision, detail_revision: u64,
	chunks: [dynamic]r3d.Mesh,
	blend_shader: ^r3d.SurfaceShader,
	layer_set: ^Terrain_Layer_Set,
	details: [dynamic]Terrain_Detail_Batch,
}

release_terrain_cache :: proc(cache: ^Terrain_Cache) {
	for mesh in cache.chunks {r3d.UnloadMesh(mesh)}
	delete(cache.chunks)
	for &batch in cache.details {release_detail_batch(&batch)}
	delete(cache.details)
	if cache.blend_shader != nil {r3d.UnloadSurfaceShader(cache.blend_shader)}
	if cache.layer_set!=nil {release_terrain_layer_set(cache.layer_set); mem.free(cache.layer_set)}
	cache^ = {}
}

release_terrains :: proc(ctx: ^Context) {
	for _,&cache in ctx.terrains {release_terrain_cache(&cache)}
	clear(&ctx.terrains)
}

prepare_terrains :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager) {
	if ctx.terrain_world_generation != world.generation {
		release_terrains(ctx)
		ctx.terrain_world_generation = world.generation
	}
	removed := make([dynamic]ecs.Entity,context.temp_allocator)
	for entity in ctx.terrains {
		if _,_,found := ecs.terrain_runtime(world,entity); !found {
			append(&removed,entity)
		}
	}
	for entity in removed {
		cache := ctx.terrains[entity]
		release_terrain_cache(&cache)
		delete_key(&ctx.terrains,entity)
	}
	for entity in ecs.entities_with_component(world,"Terrain") {
		data,revision,found := ecs.terrain_runtime(world,entity)
		if !found {continue}
		source_revision,chunk_revisions,detail_revision := ecs.terrain_render_updates(world,entity)
		cache,exists := ctx.terrains[entity]
		same_source := exists && cache.source_revision == source_revision
		if same_source && cache.revision == revision && cache.detail_revision == detail_revision && cache.layer_set==nil {continue}

		value,_ := ecs.get_terrain(world,entity)
		detail_data := ecs.terrain_committed_data(world,entity)
		ok: bool
		if same_source && len(cache.chunks) == len(chunk_revisions) {
			ok = update_terrain_cache(ctx,&cache,data,detail_data,manager,value.asset,chunk_revisions,revision,detail_revision)
		} else {
			replacement := Terrain_Cache{revision=revision,source_revision=source_revision,detail_revision=detail_revision}
			ok = build_terrain_cache(ctx,&replacement,data,detail_data,manager,value.asset)
			if ok {cache,replacement = replacement,cache}
			release_terrain_cache(&replacement)
		}
		if !ok {
			assets.report_failure(manager,{kind=.Terrain,operation=.Load,source_path=value.asset,field="mesh",asset_path=value.asset,detail="could not create terrain meshes, blend shader or detail buffers; keeping previous GPU resources"})
			continue
		}
		ctx.terrains[entity] = cache
		assets.resolve_asset_failure(manager,value.asset,"mesh",value.asset)
	}
}

build_terrain_cache :: proc(ctx: ^Context, cache: ^Terrain_Cache, data,detail_data: terrain.Data,
		manager: ^assets.Asset_Manager, source: string) -> bool {
	d := data.description
	if terrain.blend_enabled(d.blend) || len(d.layers)>0 {
		kind := 2 if len(d.layers)>0 else (1 if terrain.blend_uses_materials(d.blend) else 0)
		if ctx.terrain_shaders[kind]==nil {
			source := #load("terrain_layers.glsl",string) if kind==2 else (#load("terrain_blend_material.glsl",string) if kind==1 else #load("terrain_blend.glsl",string))
			ctx.terrain_shaders[kind]=r3d.LoadSurfaceShaderFromMemory(strings.clone_to_cstring(source,context.temp_allocator))
		}
		if ctx.terrain_shaders[kind]!=nil {cache.blend_shader=r3d.LoadSurfaceShaderAlias(ctx.terrain_shaders[kind])}
		if cache.blend_shader == nil {return false}
		if kind==2 {
			cache.layer_set=new(Terrain_Layer_Set)
			base := material_from_path(ctx,manager,d.material,{113,139,77,255})
			empty: Terrain_Layer_Set
			stage_terrain_layer_set(ctx,manager,&empty,cache.layer_set,d,base,source)
		}
	}
	controls: ^terrain.Control_Map
	surfaces_pending := cache.layer_set!=nil && cache.layer_set.parameters.id==0
	if cache.layer_set!=nil {controls=&cache.layer_set.paint.controls}
	return upload_terrain_chunks(ctx,cache,data) &&
		prepare_detail_batches(cache,detail_data,ctx.worker_pool,&ctx.frame_stats,controls,surfaces_pending=surfaces_pending)
}

update_terrain_cache :: proc(ctx: ^Context, cache: ^Terrain_Cache, data,detail_data: terrain.Data,
		manager: ^assets.Asset_Manager, source: string, chunk_revisions: []u64, revision,detail_revision: u64) -> bool {
	layer_changes: Terrain_Layer_Set
	defer release_terrain_layer_set(&layer_changes)
	controls: ^terrain.Control_Map
	surfaces_pending := false
	refresh_filtered := false
	if set := cache.layer_set; set != nil {
		base := material_from_path(ctx,manager,data.description.material,{113,139,77,255})
		stage_terrain_layer_set(ctx,manager,set,&layer_changes,data.description,base,source)
		controls = &set.paint.controls
		if layer_changes.paint.texture.id!=0 {controls=&layer_changes.paint.controls}
		surfaces_pending = set.parameters.id==0 && layer_changes.parameters.id==0
		refresh_filtered = (set.parameters.id==0 && layer_changes.parameters.id!=0) ||
			(layer_changes.paint.texture.id!=0 && len(data.description.control_maps)>0)
	}
	refresh_details := cache.detail_revision!=detail_revision
	if cache.revision==revision && !refresh_details && layer_changes.paint.texture.id==0 && layer_changes.parameters.id==0 {return true}

	// Keep the previous meshes and details together until every replacement has
	// succeeded. After the swap, the staging cache owns the old resources.
	staged: Terrain_Cache
	defer release_terrain_cache(&staged)
	selected_chunks := make([dynamic]int,context.temp_allocator)
	if cache.revision!=revision {
		for chunk_revision,index in chunk_revisions {
			if chunk_revision > cache.revision {append(&selected_chunks,index)}
		}
	}
	if len(selected_chunks)>0 && !upload_terrain_chunks(ctx,&staged,data,selected_chunks[:]) {return false}

	selected_details: [terrain.MAX_DETAIL_TYPES]int
	selected_count := 0
	if refresh_filtered && !refresh_details {
		for detail,index in detail_data.description.details {
			if detail.surface_min<=0 {continue}
			selected_details[selected_count] = index
			selected_count += 1
		}
	}
	if refresh_details && !prepare_detail_batches(&staged,detail_data,ctx.worker_pool,&ctx.frame_stats,
		controls,surfaces_pending=surfaces_pending) {return false}
	if selected_count>0 && !prepare_detail_batches(&staged,detail_data,ctx.worker_pool,&ctx.frame_stats,
		controls,selected_details[:selected_count]) {return false}

	for chunk,index in selected_chunks {cache.chunks[chunk],staged.chunks[index] = staged.chunks[index],cache.chunks[chunk]}
	if refresh_details {cache.details,staged.details = staged.details,cache.details}
	for detail,index in selected_details[:selected_count] {cache.details[detail],staged.details[index] = staged.details[index],cache.details[detail]}
	if cache.layer_set!=nil {publish_terrain_layer_set(cache.layer_set,&layer_changes)}
	cache.revision = revision
	cache.detail_revision = detail_revision
	return true
}

// Samples the installed layer set at a world point on the committed terrain.
// The point is projected onto the terrain's local X/Z coordinates.
terrain_surface_weight :: proc(ctx: ^Context, world: ^ecs.World, entity: ecs.Entity, point: [3]f32, surface: string) -> (f32,bool) {
	if ctx==nil || world==nil || ctx.terrain_world_generation!=world.generation || !ecs.is_enabled(world,entity) {return 0,false}
	cache,exists := ctx.terrains[entity]
	if !exists || cache.layer_set==nil || cache.layer_set.parameters.id==0 {return 0,false}
	source_revision,_,_ := ecs.terrain_render_updates(world,entity)
	if cache.source_revision!=source_revision {return 0,false}
	transform,valid := ecs.terrain_transform(world,entity)
	if !valid {return 0,false}
	local,invertible := ecs.inverse_transform_point_3d(transform,point)
	if !invertible {return 0,false}
	return terrain.surface_weight(ecs.terrain_committed_data(world,entity),local[0],local[2],surface,&cache.layer_set.paint.controls)
}

upload_terrain_chunk :: proc(data: terrain.Data, start_x,start_z,cells_x,cells_z: int) -> (r3d.Mesh,bool) {
	chunk := build_terrain_chunk_cpu(data,start_x,start_z,cells_x,cells_z)
	defer destroy_terrain_chunk_cpu(&chunk)
	return upload_terrain_chunk_cpu(chunk)
}

draw_terrains :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, filter:Depth_Pass_Filter={}) {
	for entity,cache in ctx.terrains {
		if depth_pass_excludes(world,entity,filter) {continue}
		if !ecs.is_enabled(world,entity) {continue}
		value,found := ecs.get_terrain(world,entity)
		t,valid := ecs.terrain_transform(world,entity)
		data,_,loaded := ecs.terrain_runtime(world,entity)
		if !found || !valid || !loaded {continue}
		material := material_from_path(ctx,manager,data.description.material,{113,139,77,255})
		shader_current := false
		if cache.blend_shader!=nil {
			source_revision,_,_ := ecs.terrain_render_updates(world,entity)
			shader_current = source_revision==cache.source_revision
		}
		if shader_current && cache.layer_set!=nil && cache.layer_set.parameters.id!=0 {
			bind_terrain_layer_set(cache.layer_set,cache.blend_shader,data.description)
			material.shader=cache.blend_shader
		} else if shader_current && cache.layer_set==nil && terrain.blend_enabled(data.description.blend) {
			b := data.description.blend
			paths := [3]string{b.grass,b.dirt,b.rock}
			names := [3]cstring{"u_grass","u_dirt","u_rock"}
			fields := [3]string{"blend.grass","blend.dirt","blend.rock"}
			ready := true
			if terrain.blend_uses_materials(b) {
				ready = bind_terrain_material_layers(ctx, manager, cache.blend_shader, b, material, value.asset)
			} else {for path,i in paths {
				texture,ok := assets.material_texture(manager,path,"anisotropic_8x",true,value.asset,fields[i])
				ready = ready && ok
				if ok {
					rl.SetTextureWrap(texture,.REPEAT)
					r3d.SetSurfaceShaderSampler(cache.blend_shader,names[i],texture)
				}
			}}
			if ready {
				// Each terrain owns a shader: R3D resolves uniforms at End(), so
				// sharing one would give every terrain the last entity's settings.
				uv := data.description.uv_scale/data.description.size
				noise := [2]f32{b.noise_scale,b.noise_strength}
				r3d.SetSurfaceShaderUniform(cache.blend_shader,"u_uv_scale",&uv)
				r3d.SetSurfaceShaderUniform(cache.blend_shader,"u_dirt_height",&b.dirt_height)
				r3d.SetSurfaceShaderUniform(cache.blend_shader,"u_rock_slope",&b.rock_slope)
				r3d.SetSurfaceShaderUniform(cache.blend_shader,"u_noise",&noise)
				material.shader = cache.blend_shader
			}
		}
		for texture in ([4]rl.Texture2D{material.albedo.texture,material.normal.texture,material.orm.texture,material.emission.texture}) {
			if texture.id != 0 {rl.SetTextureWrap(texture,.REPEAT)}
		}
		for mesh in cache.chunks {
			draw_mesh := mesh
			draw_mesh.shadowCastMode = .ON_DOUBLE_SIDED if value.shadows else .DISABLED
			r3d.DrawMeshEx(draw_mesh,material,t.position,rotation_quaternion(t),t.scale)
		}
	}
}
