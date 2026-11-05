package r3d_bridge

import "core:testing"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
barycentric_expansion_preserves_skinning_and_triangle_order :: proc(t:^testing.T) {
	vertices:=[4]r3d.Vertex{
		{position={0,0,0},texcoord={12,34},normal={0,127,0,0},tangent={127,0,0,127},color={10,20,30,40},boneIndices={4,8,12,16},boneWeights={100,80,50,25}},
		{position={1,0,0},boneIndices={1,2,3,4},boneWeights={64,64,64,63}},
		{position={0,1,0}},{position={1,1,0}},
	}
	indices:=[6]u32{0,1,2,2,1,3}
	source:=r3d.MeshData{vertices=raw_data(vertices[:]),vertexCount=4,indices=raw_data(indices[:]),indexCount=6}
	data,ok:=barycentric_mesh_data(source)
	if !testing.expect(t,ok) {return};defer r3d.UnloadMeshData(data)
	testing.expect(t,data.vertexCount==6 && data.indexCount==0 && data.indices==nil,"each triangle owns independent corners")
	colors:=[3]rl.Color{{255,0,0,255},{0,255,0,255},{0,0,255,255}}
	for corner in 0..<6 {
		expected:=vertices[indices[corner]];expected.color=colors[corner%3]
		testing.expect(t,data.vertices[corner]==expected,"positions, UVs, normals, tangents and packed skin weights survive expansion")
	}
	unindexed,unindexed_ok:=barycentric_mesh_data({vertices=data.vertices,vertexCount=data.vertexCount})
	if !testing.expect(t,unindexed_ok) {return};defer r3d.UnloadMeshData(unindexed)
	for corner in 0..<6 {testing.expect(t,unindexed.vertices[corner]==data.vertices[corner])}
	indices[5]=99
	invalid,accepted:=barycentric_mesh_data(source);defer r3d.UnloadMeshData(invalid)
	testing.expect(t,!accepted,"invalid indices fail without leaking the replacement storage")
}
