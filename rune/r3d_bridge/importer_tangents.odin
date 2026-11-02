package r3d_bridge

import "core:math"
import "core:math/linalg"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// R3D's missing-UV fallback is +X, which is parallel to an X-facing normal.
// Its shader normalizes cross(N,T), so even a neutral normal map then produces
// NaNs. Preserve authored frames and replace only unusable packed tangents.
repair_imported_mesh_tangents :: proc(vertices: []r3d.Vertex) -> int {
	repaired := 0
	for &vertex in vertices {
		n := rl.Vector3{f32(vertex.normal[0]),f32(vertex.normal[1]),f32(vertex.normal[2])}
		n2 := linalg.dot(n,n)
		if n2 == 0 {continue} // A missing normal is a separate geometry defect.
		n /= math.sqrt(n2)
		t := rl.Vector3{f32(vertex.tangent[0]),f32(vertex.tangent[1]),f32(vertex.tangent[2])}
		t2 := linalg.dot(t,t)
		b := linalg.cross(n,t)
		valid_basis := t2 > 0 && linalg.dot(b,b) > t2*1e-6
		if valid_basis {
			if vertex.tangent[3] != 0 {continue}
			// Zero handedness also collapses the shader's bitangent.
			vertex.tangent[3] = 127
		} else {
			// Project the least-aligned axis onto the normal's tangent plane.
			axis := 0
			if abs(n[1]) < abs(n[axis]) {axis=1}
			if abs(n[2]) < abs(n[axis]) {axis=2}
			t = {}
			t[axis] = 1
			t -= n*linalg.dot(n,t)
			t /= math.sqrt(linalg.dot(t,t))
			handedness := f32(-1) if vertex.tangent[3] < 0 else f32(1)
			r3d.PackTangent(&vertex.tangent[0], {t[0],t[1],t[2],handedness})
		}
		repaired += 1
	}
	return repaired
}

// Conversion and any corrective upload remain on the graphics owner. The
// temporary retained mesh data uses native allocation and is released even if
// an upload fails; the caller can then discard the whole replacement model.
repair_imported_model_tangents :: proc(model: ^r3d.Model) -> bool {
	if model.meshData == nil {return true}
	defer {
		for i in 0..<model.meshCount {r3d.UnloadMeshData(model.meshData[i])}
		rl.MemFree(model.meshData)
		model.meshData = nil
	}
	for i in 0..<model.meshCount {
		data := model.meshData[i]
		if data.vertices == nil || data.vertexCount <= 0 {continue}
		if repair_imported_mesh_tangents(data.vertices[:int(data.vertexCount)]) == 0 {continue}
		if !r3d.UpdateMesh(&model.meshes[i],data,&model.meshes[i].aabb) {return false}
	}
	return true
}
