package r3d_bridge

import r3d "r3d:r3d"
import rl "vendor:raylib"

// Opt in before the model's first load. RGB vertex colors become triangle
// barycentrics; shaders must consume COLOR and restore the desired vertex tint.
// Indices, bone numbers and animation tracks are never renumbered.
enable_model_barycentric_colors :: proc(ctx:^Context,path:string)->bool {
	if ctx==nil || !ctx.initialized || path=="" {return false}
	if ctx.barycentric_models[path] {return true}
	if _,loaded:=ctx.models[path];loaded {return false}
	ctx.barycentric_models[retain_path(ctx,path)]=true
	return true
}

// CPU-only expansion preserves every original attribute except vertex color.
// Returned storage uses R3D allocation and belongs to the caller.
barycentric_mesh_data :: proc(source:r3d.MeshData)->(r3d.MeshData,bool) {
	if source.vertices==nil || source.vertexCount<=0 || source.indexCount<0 {return {},false}
	indexed:=source.indexCount>0
	if indexed && source.indices==nil {return {},false}
	count:=source.indexCount if indexed else source.vertexCount
	if count%3!=0 {return {},false}
	data:=r3d.LoadMeshData(count,0)
	if data.vertices==nil {return {},false}
	colors:=[3]rl.Color{{255,0,0,255},{0,255,0,255},{0,0,255,255}}
	for corner in 0..<int(count) {
		index:=source.indices[corner] if indexed else u32(corner)
		if index>=u32(source.vertexCount) {r3d.UnloadMeshData(data);return {},false}
		data.vertices[corner]=source.vertices[index]
		data.vertices[corner].color=colors[corner%3]
	}
	data.vertexCount=count
	return data,true
}

prepare_imported_model_barycentrics :: proc(model:^r3d.Model)->bool {
	if model.meshData==nil {return false}
	for index in 0..<model.meshCount {
		original:=model.meshes[index]
		if original.primitiveType!=.TRIANGLES {return false}
		data,expanded:=barycentric_mesh_data(model.meshData[index])
		if !expanded {return false}
		replacement:=r3d.LoadMesh(.TRIANGLES,data,&original.aabb)
		if !r3d.IsMeshValid(replacement) {r3d.UnloadMeshData(data);return false}
		replacement.shadowCastMode=original.shadowCastMode
		replacement.layerMask=original.layerMask
		r3d.UnloadMesh(original)
		r3d.UnloadMeshData(model.meshData[index])
		model.meshData[index]=data
		model.meshes[index]=replacement
	}
	return true
}
