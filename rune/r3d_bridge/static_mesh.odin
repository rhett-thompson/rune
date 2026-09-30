package r3d_bridge

import "rune:ecs"
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
			t:=[3]f32{1,0,0} if n[0]==0 else [3]f32{0,0,1}
			vertices[i]=r3d.MakeVertex(v.position,{v.position[0]*0.25,v.position[2]*0.25},n,{t[0],t[1],t[2],1},rl.Color{v.color[0],v.color[1],v.color[2],v.color[3]})
		}
		mesh:=r3d.LoadMesh(.TRIANGLES,{vertices=raw_data(vertices),indices=raw_data(state.data.indices),vertexCount=i32(len(vertices)),indexCount=i32(len(state.data.indices)),vertexCapacity=i32(len(vertices)),indexCapacity=i32(len(state.data.indices))},nil)
		delete(vertices)
		if !r3d.IsMeshValid(mesh) {continue}
		mesh.shadowCastMode=.ON_DOUBLE_SIDED
		if old,ok:=ctx.static_meshes[entity]; ok {r3d.UnloadMesh(old.mesh)}
		ctx.static_meshes[entity]={mesh,state.revision}
	}
}

draw_static_meshes :: proc(ctx: ^Context, world: ^ecs.World) {
	material:=r3d.GetDefaultMaterial()
	for entity,cache in ctx.static_meshes {
		if !ecs.is_enabled(world,entity) {continue}
		t,valid:=ecs.terrain_transform(world,entity)
		if valid {r3d.DrawMeshEx(cache.mesh,material,t.position,rotation_quaternion(t),t.scale)}
	}
}
