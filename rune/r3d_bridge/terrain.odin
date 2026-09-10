package r3d_bridge

import "core:math/linalg"
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
}

release_terrain_cache :: proc(cache: ^Terrain_Cache) {
	for mesh in cache.chunks {r3d.UnloadMesh(mesh)}
	delete(cache.chunks)
	if cache.blend_shader != nil {r3d.UnloadSurfaceShader(cache.blend_shader)}
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
		if terrain.blend_enabled(d.blend) {
			source :: #load("terrain_blend.glsl", string)
			cache.blend_shader = r3d.LoadSurfaceShaderFromMemory(strings.clone_to_cstring(source,context.temp_allocator))
			ok = cache.blend_shader != nil
		}
		for z := 0; z < d.resolution[1]-1 && ok; z += d.chunk_cells {
			for x := 0; x < d.resolution[0]-1; x += d.chunk_cells {
				mesh,valid := upload_terrain_chunk(data,x,z,min(d.chunk_cells,d.resolution[0]-1-x),min(d.chunk_cells,d.resolution[1]-1-z))
				if !valid {ok=false; break}
				append(&cache.chunks,mesh)
			}
		}
		if !ok {
			release_terrain_cache(&cache)
			value,_ := ecs.get_terrain(world,entity)
			assets.report_failure(manager,{kind=.Terrain,operation=.Load,source_path=value.asset,field="mesh",asset_path=value.asset,detail="could not create terrain meshes or blend shader; keeping previous GPU resources"})
			continue
		}
		if old,exists := ctx.terrains[entity]; exists {release_terrain_cache(&old)}
		ctx.terrains[entity] = cache
		value,_ := ecs.get_terrain(world,entity)
		assets.resolve_asset_failure(manager,value.asset,"mesh",value.asset)
	}
}

upload_terrain_chunk :: proc(data: terrain.Data, start_x,start_z,cells_x,cells_z: int) -> (r3d.Mesh,bool) {
	w,h := cells_x+1,cells_z+1
	vertices := make([]r3d.Vertex,w*h)
	defer delete(vertices)
	indices := make([]u32,cells_x*cells_z*6)
	defer delete(indices)
	d := data.description
	for z in 0..<h {for x in 0..<w {
		gx,gz := start_x+x,start_z+z
		n := terrain.normal(data,gx,gz)
		t := linalg.normalize([3]f32{n[1],-n[0],0})
		vertices[z*w+x] = r3d.MakeVertex(terrain.position(data,gx,gz),
			{f32(gx)/f32(d.resolution[0]-1)*d.uv_scale[0],f32(gz)/f32(d.resolution[1]-1)*d.uv_scale[1]},
			n,{t[0],t[1],t[2],-1},rl.WHITE)
	}}
	i := 0
	for z in 0..<cells_z {for x in 0..<cells_x {for index in terrain.cell_indices(x,z,w) {indices[i]=index; i+=1}}}
	mesh := r3d.LoadMesh(.TRIANGLES,{vertices=raw_data(vertices),indices=raw_data(indices),vertexCount=i32(len(vertices)),indexCount=i32(len(indices)),vertexCapacity=i32(len(vertices)),indexCapacity=i32(len(indices))},nil)
	return mesh,r3d.IsMeshValid(mesh)
}

draw_terrains :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager) {
	for entity,cache in ctx.terrains {
		if !ecs.is_enabled(world,entity) {continue}
		value,found := ecs.get_terrain(world,entity)
		t,valid := ecs.terrain_transform(world,entity)
		data,_,loaded := ecs.terrain_runtime(world,entity)
		if !found || !valid || !loaded {continue}
		material := material_from_path(ctx,manager,data.description.material,{113,139,77,255})
		if cache.blend_shader != nil {
			b := data.description.blend
			paths := [3]string{b.grass,b.dirt,b.rock}
			names := [3]cstring{"u_grass","u_dirt","u_rock"}
			fields := [3]string{"blend.grass","blend.dirt","blend.rock"}
			ready := true
			for path,i in paths {
				texture,ok := assets.material_texture(manager,path,"anisotropic_8x",true,value.asset,fields[i])
				ready = ready && ok
				if ok {
					rl.SetTextureWrap(texture,.REPEAT)
					r3d.SetSurfaceShaderSampler(cache.blend_shader,names[i],texture)
				}
			}
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
