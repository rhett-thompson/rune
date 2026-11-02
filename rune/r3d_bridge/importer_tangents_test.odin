package r3d_bridge

import "core:math"
import "core:math/linalg"
import "core:testing"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
imported_tangents_repair_parallel_and_missing_frames :: proc(t: ^testing.T) {
	for normal in ([8][3]i8{{127,0,0},{-127,0,0},{0,127,0},{0,-127,0},{0,0,127},{0,0,-127},{73,73,73},{-73,73,-73}}) {
		for missing in ([2]bool{false,true}) {
			vertex := r3d.Vertex{
				position={1,2,3},normal={normal[0],normal[1],normal[2],0},
				tangent={normal[0],normal[1],normal[2],-127},
				texcoord={123,456},color={12,34,56,78},boneIndices={1,2,3,4},boneWeights={10,20,30,195},
			}
			if missing {vertex.tangent={}}
			before := vertex
			vertices := [1]r3d.Vertex{vertex}
			testing.expect(t,repair_imported_mesh_tangents(vertices[:])==1)
			n := r3d.UnpackNormal(&vertices[0].normal[0])
			tangent := r3d.UnpackTangent(&vertices[0].tangent[0])
			tn := rl.Vector3{tangent[0],tangent[1],tangent[2]}
			testing.expect(t,abs(linalg.dot(n,tn))<0.02,"replacement tangent must remain orthogonal after SNORM8 packing")
			testing.expect(t,linalg.dot(linalg.cross(n,tn),linalg.cross(n,tn))>0.95,"the shader bitangent must have a finite nonzero length")
			testing.expect(t,tangent[3]==(f32(1) if missing else f32(-1)),"preserve valid handedness and default missing handedness to +1")
			before.tangent=vertices[0].tangent
			testing.expect(t,before==vertices[0],"repair must preserve positions, normals, UVs, colors and skinning weights")
			testing.expect(t,repair_imported_mesh_tangents(vertices[:])==0,"repaired packed frames are stable")
		}
	}
}

@(test)
imported_tangents_preserve_authored_frames_and_repair_zero_handedness :: proc(t: ^testing.T) {
	vertices := [3]r3d.Vertex{
		{normal={0,0,127,0},tangent={127,0,0,-127}},
		{normal={73,73,73,0},tangent={90,-90,0,127}},
		{normal={0,127,0,0},tangent={127,0,0,0}},
	}
	before := vertices
	testing.expect(t,repair_imported_mesh_tangents(vertices[:])==1)
	testing.expect(t,vertices[0]==before[0] && vertices[1]==before[1],"valid authored frames must remain byte-identical")
	before[2].tangent[3]=127
	testing.expect(t,vertices[2]==before[2],"a zero handedness repair preserves the valid tangent direction")
	// The GPU failure specifically requires the X-facing no-UV fallback. Rotating
	// its repaired basis by -90 degrees must still yield a finite +Z normal.
	vertex := [1]r3d.Vertex{{normal={127,0,0,0},tangent={127,0,0,127}}}
	testing.expect(t,repair_imported_mesh_tangents(vertex[:])==1)
	n := rl.Vector3{0,0,1}
	tn := r3d.UnpackTangent(&vertex[0].tangent[0])
	tangent := rl.Vector3{-tn[2],tn[1],tn[0]}
	bitangent := linalg.cross(n,tangent)*tn[3]
	testing.expect(t,linalg.dot(bitangent,bitangent)>0.95)
	// RGBA8's neutral normal has a small XY quantization bias. This exercises
	// the actual TBN multiplication rather than checking only the normal.
	shaded := tangent*(1.0/255.0)+bitangent*(1.0/255.0)+n
	shaded /= math.sqrt(linalg.dot(shaded,shaded))
	testing.expect(t,shaded[2]>0.99 && !math.is_nan(shaded[0]) && !math.is_nan(shaded[1]))
}
