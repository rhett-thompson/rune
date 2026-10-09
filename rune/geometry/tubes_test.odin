package geometry

import "core:testing"
import "core:math"
import "core:math/linalg"

expect_tube_winding :: proc(t: ^testing.T, mesh: Mesh) {
	testing.expect(t,valid(mesh))
	for i:=0; i<len(mesh.indices); i+=3 {
		a,b,c:=mesh.vertices[mesh.indices[i]],mesh.vertices[mesh.indices[i+1]],mesh.vertices[mesh.indices[i+2]]
		testing.expect(t,linalg.dot(linalg.cross(b.position-a.position,c.position-a.position),a.normal+b.normal+c.normal)>0,"every side and cap faces outward")
	}
}

@(test)
tubes_preserve_radius_caps_winding_and_append_offsets :: proc(t: ^testing.T) {
	paths:=[3][2][3]f32{{{0,0,0},{5,0,0}},{{0,0,0},{0,5,0}},{{0,0,0},{0,0,5}}}
	for &points in paths {
		mesh: Mesh; defer destroy_mesh(&mesh)
		color:=[4]u8{255,112,16,255}
		testing.expect(t,append_tube(&mesh,points[:],0.25,color=color))
		testing.expect(t,len(mesh.vertices)==34 && len(mesh.indices)==96)
		for i in 0..<16 {
			vertex:=mesh.vertices[i]
			testing.expect(t,abs(linalg.length(vertex.position-points[i/8])-0.25)<1e-5 && vertex.color==color,"side rings lie at the supplied radius")
		}
		tangent:=linalg.normalize(points[1]-points[0])
		for i in 16..<25 {testing.expect(t,mesh.vertices[i].normal==-tangent,"start cap normals are flat")}
		for i in 25..<34 {testing.expect(t,mesh.vertices[i].normal==tangent,"end cap normals are flat")}
		original_vertex,original_index:=mesh.vertices[0],mesh.indices[0]
		testing.expect(t,append_tube(&mesh,points[:],0.5,sides=6))
		testing.expect(t,mesh.vertices[0]==original_vertex && mesh.indices[0]==original_index)
		for index in mesh.indices[96:] {testing.expect(t,index>=34,"additional paths reference only their own vertices")}
		expect_tube_winding(t,mesh)
	}
}

@(test)
tubes_follow_bent_paths_deterministically_without_frame_flips :: proc(t: ^testing.T) {
	points: [25][3]f32
	for &p,i in points {
		t:=f32(i)/f32(len(points)-1)
		p={t*30,-8*4*t*(1-t),math.sin(t*f32(math.PI))*3}
	}
	a,b: Mesh; defer destroy_mesh(&a); defer destroy_mesh(&b)
	testing.expect(t,append_tube(&a,points[:],0.2) && append_tube(&b,points[:],0.2))
	expect_tube_winding(t,a)
	testing.expect(t,len(a.vertices)==len(b.vertices) && len(a.indices)==len(b.indices))
	for vertex,i in a.vertices {testing.expect(t,vertex==b.vertices[i],"repeated paths produce identical vertices")}
	for index,i in a.indices {testing.expect(t,index==b.indices[i],"repeated paths produce identical indices")}
	for i in 0..<len(points)-1 {testing.expect(t,linalg.dot(a.vertices[i*8].normal,a.vertices[(i+1)*8].normal)>0.9,"successive frames turn smoothly")}
}

@(test)
tubes_reject_invalid_input_without_mutating_existing_buffers :: proc(t: ^testing.T) {
	good:=[2][3]f32{{0,0,0},{0,0,5}}
	mesh: Mesh; defer destroy_mesh(&mesh)
	testing.expect(t,append_tube(&mesh,good[:],0.25))
	vertices,indices:=mesh.vertices,mesh.indices
	original_vertices:=make([]Vertex,len(vertices)); defer delete(original_vertices)
	original_indices:=make([]u32,len(indices)); defer delete(original_indices)
	copy(original_vertices,vertices[:]); copy(original_indices,indices[:])
	infinity:=transmute(f32)u32(0x7f800000)
	not_a_number:=transmute(f32)u32(0x7fc00000)
	invalid:=[4][3][3]f32{
		{{0,0,0},{0,0,0},{0,0,1}},
		{{0,0,0},{0,0,1},{0,0,0}},
		{{0,0,0},{infinity,0,0},{0,0,1}},
		{{0,0,0},{not_a_number,0,0},{0,0,1}},
	}
	for &points in invalid {testing.expect(t,!append_tube(&mesh,points[:],0.25))}
	testing.expect(t,!append_tube(&mesh,good[:1],0.25))
	testing.expect(t,!append_tube(&mesh,good[:],0))
	testing.expect(t,!append_tube(&mesh,good[:],infinity))
	testing.expect(t,!append_tube(&mesh,good[:],not_a_number))
	testing.expect(t,!append_tube(&mesh,good[:],0.25,sides=2))
	testing.expect(t,!append_tube(&mesh,good[:],0.25,sides=65))
	testing.expect(t,!append_tube(nil,good[:],0.25))
	tight_bend:=[3][3]f32{{0,0,0},{0,0,1},{0,1,1}}
	testing.expect(t,!append_tube(&mesh,tight_bend[:],100),"radius that folds a bend is rejected")
	testing.expect(t,len(mesh.vertices)==len(vertices) && len(mesh.indices)==len(indices))
	testing.expect(t,raw_data(mesh.vertices)==raw_data(vertices) && raw_data(mesh.indices)==raw_data(indices),"failed append preserves allocations")
	for vertex,i in mesh.vertices {testing.expect(t,vertex==original_vertices[i],"failed append preserves existing vertices")}
	for index,i in mesh.indices {testing.expect(t,index==original_indices[i],"failed append preserves existing indices")}
	expect_tube_winding(t,mesh)
}
