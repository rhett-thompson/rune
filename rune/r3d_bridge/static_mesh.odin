package r3d_bridge

import "rune:ecs"
import "rune:assets"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Static_Mesh_Cache :: struct {
	mesh: r3d.Mesh,
	revision: u64,
	pose: ecs.Transform,
	transform: rl.Matrix,
	bounds: rl.BoundingBox,
	pose_cached: bool,
	node_version: u64,
	enabled, valid, shadows: bool,
	occlusion_faces: []Occlusion_Face,
	occlusion_faces_ready, occlusion_opaque, occlusion_eligible, occluded: bool,
	occlusion_cull: r3d.CullMode,
}

release_static_meshes :: proc(ctx: ^Context) {
	for _,cache in ctx.static_meshes {r3d.UnloadMesh(cache.mesh); delete(cache.occlusion_faces)}
	clear(&ctx.static_meshes)
	clear(&ctx.static_nodes)
	for _,group in ctx.static_groups {delete(group.members)}
	clear(&ctx.static_groups)
	ctx.occlusion={}
}

prepare_static_meshes :: proc(ctx: ^Context, world: ^ecs.World) {
	if ctx.static_mesh_generation!=world.generation {release_static_meshes(ctx); ctx.static_mesh_generation=world.generation}
	removed := make([dynamic]ecs.Entity,context.temp_allocator)
	for entity in ctx.static_meshes {if _,ok:=world.static_meshes[entity]; !ok {append(&removed,entity)}}
	for entity in removed {r3d.UnloadMesh(ctx.static_meshes[entity].mesh); delete(ctx.static_meshes[entity].occlusion_faces); delete_key(&ctx.static_meshes,entity); ctx.occlusion.dirty=true}
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
		if old,ok:=ctx.static_meshes[entity]; ok {r3d.UnloadMesh(old.mesh); delete(old.occlusion_faces)}
		ctx.static_meshes[entity]={mesh=mesh,revision=state.revision}
		ctx.frame_stats.static_uploads += 1
		ctx.occlusion.dirty=true
	}
}

// Dominant-axis planar UVs keep wall detail from collapsing to a single row.
// Tangent handedness follows the projected V axis on either side of a surface.
static_mesh_projection :: proc(p,n:[3]f32) -> ([2]f32,[4]f32) {
	if abs(n[0])>abs(n[1]) && abs(n[0])>=abs(n[2]) {return {p[2]*0.25,p[1]*0.25},{0,0,1,-1 if n[0]>0 else 1}}
	if abs(n[2])>abs(n[1]) {return {p[0]*0.25,p[1]*0.25},{1,0,0,1 if n[2]>0 else -1}}
	return {p[0]*0.25,p[2]*0.25},{1,0,0,-1 if n[1]>0 else 1}
}

draw_static_meshes :: proc(ctx: ^Context, world: ^ecs.World, manager:^assets.Asset_Manager,camera:rl.Camera3D) {
	ctx.frame_stats.static_meshes = len(ctx.static_meshes)
	if ctx.static_optimizations_disabled {
		for entity,cache in ctx.static_meshes {
			if !ecs.is_enabled(world,entity) {continue}
			pose,valid:=ecs.terrain_transform(world,entity)
			if !valid {continue}
			ctx.frame_stats.static_enabled += 1
			submit_static_mesh(ctx,world,manager,entity,cache,{},&pose)
		}
		return
	}
	prepare_static_groups(ctx,world)
	occlusion_started:=rl.GetTime()
	prepare_occlusion(ctx,world,manager,camera)
	ctx.frame_stats.occlusion_cpu_ms=(rl.GetTime()-occlusion_started)*1000
	if ctx.occlusion_enabled {ctx.frame_stats.occlusion_occluders=ctx.occlusion.count}
	frustum:=r3d.GetFrustum()
	for _,group in ctx.static_groups {
		ctx.frame_stats.static_clusters += 1
		outside:=!r3d.FrustumIntersectsBoundingBox(&frustum,group.bounds)
		if outside {ctx.frame_stats.static_clusters_outside_view += 1}
		// Camera-hidden casters may still shadow visible objects. Let R3D
		// test their cluster against each shadow frustum during End().
		if outside && (ctx.shadows_disabled || !group.shadows) {
			ctx.frame_stats.static_meshes_skipped += len(group.members)
			continue
		}
		r3d.BeginCluster(group.bounds)
		for entity in group.members {
			cache:=ctx.static_meshes[entity]
			if outside && !cache.shadows {
				ctx.frame_stats.static_meshes_skipped += 1
				continue
			}
			hidden:=ctx.occlusion_enabled && ctx.occlusion.prepared && cache.occluded
			if hidden {
				ctx.frame_stats.static_meshes_occluded+=1
				ctx.frame_stats.static_scene_triangles_avoided+=int(cache.mesh.indexCount)/3
				if ctx.shadows_disabled || !cache.shadows {ctx.frame_stats.static_meshes_skipped+=1; continue}
				ctx.frame_stats.static_shadow_only+=1
			}
			submit_static_mesh(ctx,world,manager,entity,cache,cache.transform,shadow_only=hidden)
		}
		r3d.EndCluster()
	}
}

submit_static_mesh :: proc(ctx:^Context,world:^ecs.World,manager:^assets.Asset_Manager,entity:ecs.Entity,cache:Static_Mesh_Cache,transform:rl.Matrix,uncached_pose:^ecs.Transform=nil,shadow_only:=false) {
	material:=r3d.GetDefaultMaterial()
	mesh:=cache.mesh
	if renderer,found:=ecs.get_mesh_renderer(world,entity); found && renderer.primitive=="static" {
		material=material_from_path(ctx,manager,renderer.material,renderer.color)
		mesh.shadowCastMode=.ON_DOUBLE_SIDED if renderer.shadows else .DISABLED
	}
	if shadow_only {mesh.shadowCastMode=.ONLY_DOUBLE_SIDED}
	if uncached_pose!=nil {
		pose:=uncached_pose^
		r3d.DrawMeshEx(mesh,material,pose.position,rotation_quaternion(pose),pose.scale)
	} else {r3d.DrawMeshPro(mesh,material,transform)}
	ctx.frame_stats.static_submitted += 1
	ctx.frame_stats.static_triangles_submitted += int(mesh.indexCount)/3
}
