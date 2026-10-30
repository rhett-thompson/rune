package r3d_bridge

import "core:mem"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Terrain_Cache :: struct {
	revision: u64,
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
		if cached,exists := ctx.terrains[entity]; exists && cached.revision == revision {continue}
		cache := Terrain_Cache{revision=revision,chunks=make([dynamic]r3d.Mesh)}
		d := data.description
		ok := true
		if terrain.blend_enabled(d.blend) || len(d.layers)>0 {
			kind := 2 if len(d.layers)>0 else (1 if terrain.blend_uses_materials(d.blend) else 0)
			if ctx.terrain_shaders[kind]==nil {
				source := #load("terrain_layers.glsl",string) if kind==2 else (#load("terrain_blend_material.glsl",string) if kind==1 else #load("terrain_blend.glsl",string))
				ctx.terrain_shaders[kind]=r3d.LoadSurfaceShaderFromMemory(strings.clone_to_cstring(source,context.temp_allocator))
			}
			if ctx.terrain_shaders[kind]!=nil {cache.blend_shader=r3d.LoadSurfaceShaderAlias(ctx.terrain_shaders[kind])}
			if kind==2 {cache.layer_set=new(Terrain_Layer_Set)}
			ok = cache.blend_shader != nil
		}
		if ok {ok=upload_terrain_chunks(ctx,&cache,data)}
		if ok {ok=prepare_detail_batches(&cache,data,ctx.worker_pool,&ctx.frame_stats)}
		if !ok {
			release_terrain_cache(&cache)
			value,_ := ecs.get_terrain(world,entity)
			assets.report_failure(manager,{kind=.Terrain,operation=.Load,source_path=value.asset,field="mesh",asset_path=value.asset,detail="could not create terrain meshes, blend shader or detail buffers; keeping previous GPU resources"})
			continue
		}
		if old,exists := ctx.terrains[entity]; exists {release_terrain_cache(&old)}
		ctx.terrains[entity] = cache
		value,_ := ecs.get_terrain(world,entity)
		assets.resolve_asset_failure(manager,value.asset,"mesh",value.asset)
	}
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
		if cache.blend_shader != nil && len(data.description.layers)>0 {
			if bind_terrain_layer_set(ctx,manager,cache.layer_set,cache.blend_shader,data.description,material,value.asset) {material.shader=cache.blend_shader}
		} else if cache.blend_shader != nil {
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
