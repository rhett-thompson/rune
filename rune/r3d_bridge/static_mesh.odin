package r3d_bridge

import "rune:ecs"
import "rune:assets"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Static_Mesh_Cache :: struct {
	mesh: r3d.Mesh,
	revision: u64,
}

release_static_meshes :: proc(ctx: ^Context) {
	for _,cache in ctx.static_meshes {r3d.UnloadMesh(cache.mesh)}
	clear(&ctx.static_meshes)
}

prepare_static_meshes :: proc(ctx: ^Context, world: ^ecs.World) {
	if ctx.static_mesh_generation!=world.generation {release_static_meshes(ctx); ctx.static_mesh_generation=world.generation}
	removed := make([dynamic]ecs.Entity,context.temp_allocator)
	for entity in ctx.static_meshes {if _,ok:=world.static_meshes[entity]; !ok {append(&removed,entity)}}
	for entity in removed {r3d.UnloadMesh(ctx.static_meshes[entity].mesh); delete_key(&ctx.static_meshes,entity)}
	for entity,state in world.static_meshes {
		if old,ok:=ctx.static_meshes[entity]; ok && old.revision==state.revision {continue}
		vertices:=make([]r3d.Vertex,len(state.data.vertices))
		for v,i in state.data.vertices {
			n:=v.normal
			uv,tangent:=static_mesh_projection(v.position,n)
			vertices[i]=r3d.MakeVertex(v.position,uv,n,tangent,rl.Color{v.color[0],v.color[1],v.color[2],v.color[3]})
		}
		mesh:=r3d.LoadMesh(.TRIANGLES,{vertices=raw_data(vertices),indices=raw_data(state.data.indices),vertexCount=i32(len(vertices)),indexCount=i32(len(state.data.indices)),vertexCapacity=i32(len(vertices)),indexCapacity=i32(len(state.data.indices))},nil)
		delete(vertices)
		if !r3d.IsMeshValid(mesh) {continue}
		mesh.shadowCastMode=.ON_DOUBLE_SIDED
		if old,ok:=ctx.static_meshes[entity]; ok {r3d.UnloadMesh(old.mesh)}
		ctx.static_meshes[entity]={mesh,state.revision}
	}
}

// Dominant-axis planar UVs keep wall detail from collapsing to a single row.
// Tangent handedness follows the projected V axis on either side of a surface.
static_mesh_projection :: proc(p,n:[3]f32) -> ([2]f32,[4]f32) {
	if abs(n[0])>abs(n[1]) && abs(n[0])>=abs(n[2]) {return {p[2]*0.25,p[1]*0.25},{0,0,1,-1 if n[0]>0 else 1}}
	if abs(n[2])>abs(n[1]) {return {p[0]*0.25,p[1]*0.25},{1,0,0,1 if n[2]>0 else -1}}
	return {p[0]*0.25,p[2]*0.25},{1,0,0,-1 if n[1]>0 else 1}
}

draw_static_meshes :: proc(ctx: ^Context, world: ^ecs.World, manager:^assets.Asset_Manager) {
	for entity,cache in ctx.static_meshes {
		if !ecs.is_enabled(world,entity) {continue}
		material:=r3d.GetDefaultMaterial()
		mesh:=cache.mesh
		if renderer,found:=ecs.get_mesh_renderer(world,entity); found && renderer.primitive=="static" {
			material=material_from_path(ctx,manager,renderer.material,renderer.color)
			mesh.shadowCastMode=.ON_DOUBLE_SIDED if renderer.shadows else .DISABLED
		}
		t,valid:=ecs.terrain_transform(world,entity)
		if valid {r3d.DrawMeshEx(mesh,material,t.position,rotation_quaternion(t),t.scale)}
	}
}
