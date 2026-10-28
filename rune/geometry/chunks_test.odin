package geometry

import "core:testing"
import "core:math/linalg"
import "rune:jobs"

// Expand extracted rectangles into unit faces to compare coverage independently
// of greedy merge boundaries and triangle counts.
unit_faces :: proc(mesh: Mesh, volume: Volume) -> map[[5]int]int {
	faces:=make(map[[5]int]int)
	for i:=0; i<len(mesh.vertices); i+=4 {
		a,c:=mesh.vertices[i],mesh.vertices[i+2]
		axis:=0; for n,j in a.normal {if n!=0 {axis=j; break}}
		u,v:=(axis+1)%3,(axis+2)%3
		low,high:[3]int
		for j in 0..<3 {low[j]=int((a.position[j]-volume.origin[j])/volume.spacing); high[j]=int((c.position[j]-volume.origin[j])/volume.spacing)}
		for y in low[v]..<high[v] {for x in low[u]..<high[u] {faces[{axis,int(a.normal[axis]),low[axis],x,y}]+=1}}
	}
	return faces
}

@(test)
chunked_surfaces_preserve_coverage_winding_and_bounds :: proc(t: ^testing.T) {
	v:=Volume{size={5,4,7},spacing=0.25,origin={-2,-1,3},cells=make([]u8,5*4*7)}; defer delete(v.cells)
	fill_box(v,{0,0,0},v.size,1)
	fill_box(v,{1,1,1},{4,3,6},0) // internal cavity crosses every chunk axis
	fill_box(v,{3,0,0},{5,1,7},2) // solid/solid material border remains hidden
	colors:=[3][4]u8{{},{100,120,140,255},{200,160,120,255}}
	whole,ok:=surface(v,colors[:]); testing.expect(t,ok); defer destroy_mesh(&whole)
	chunks,chunks_ok:=surface_chunks(v,colors[:],{2,2,3}); testing.expect(t,chunks_ok); defer destroy_mesh_chunks(&chunks)
	expected:=unit_faces(whole,v); defer delete(expected)
	actual:=make(map[[5]int]int); defer delete(actual)
	for chunk in chunks {
		testing.expect(t,valid(chunk.mesh))
		faces:=unit_faces(chunk.mesh,v); for key,count in faces {actual[key]+=count}; delete(faces)
		for vertex in chunk.mesh.vertices {for axis in 0..<3 {
			p:=(vertex.position[axis]-v.origin[axis])/v.spacing
			testing.expect(t,p>=f32(chunk.low[axis]) && p<=f32(chunk.high[axis]),"vertices stay inside logical chunk bounds")
		}}
		for i:=0; i<len(chunk.mesh.indices); i+=3 {
			a,b,c:=chunk.mesh.vertices[chunk.mesh.indices[i]],chunk.mesh.vertices[chunk.mesh.indices[i+1]],chunk.mesh.vertices[chunk.mesh.indices[i+2]]
			testing.expect(t,linalg.dot(linalg.cross(b.position-a.position,c.position-a.position),a.normal)>0,"outward winding is preserved")
		}
	}
	testing.expect(t,len(actual)==len(expected),"chunking adds no internal faces and loses no exposed faces")
	for key,count in expected {testing.expect(t,count==1 && actual[key]==1,"each exposed unit face appears once across chunks")}
	repeat,repeat_ok:=surface_chunks(v,colors[:],{2,2,3}); testing.expect(t,repeat_ok && len(repeat)==len(chunks)); defer destroy_mesh_chunks(&repeat)
	for chunk,i in repeat {testing.expect(t,chunk.coordinate==chunks[i].coordinate && len(chunk.mesh.vertices)==len(chunks[i].mesh.vertices)); for vertex,j in chunk.mesh.vertices {testing.expect(t,vertex==chunks[i].mesh.vertices[j],"chunk order and geometry repeat exactly")}}
}

@(test)
chunk_extraction_omits_empty_chunks_and_rejects_invalid_input :: proc(t: ^testing.T) {
	v:=Volume{size={8,2,4},spacing=1,cells=make([]u8,64)}; defer delete(v.cells)
	colors:=[2][4]u8{{},{255,255,255,255}}
	fill_box(v,{6,0,0},{8,1,2},1)
	chunks,ok:=surface_chunks(v,colors[:],{2,2,2}); testing.expect(t,ok && len(chunks)==1 && chunks[0].coordinate==([3]int{3,0,0})); destroy_mesh_chunks(&chunks)
	_,ok=surface_chunks(v,colors[:],{0,2,2}); testing.expect(t,!ok)
	v.cells[0]=2; _,ok=surface_chunks(v,colors[:],{2,2,2}); testing.expect(t,!ok,"invalid palettes are checked before extraction")
	v.cells[0]=0; for &cell in v.cells {cell=0}; _,ok=surface_chunks(v,colors[:],{2,2,2}); testing.expect(t,!ok,"fully empty volume matches surface's no-mesh result")
}

@(test)
parallel_chunk_extraction_matches_serial_vertices_indices_and_order :: proc(t:^testing.T) {
	pool:=jobs.create(3,1)
	if !testing.expect(t,pool!=nil) {return}
	defer jobs.destroy(pool)
	v:=Volume{size={19,11,23},spacing=0.25,origin={-3,1,7},cells=make([]u8,19*11*23)};defer delete(v.cells)
	colors:=[4][4]u8{{},{80,110,150,255},{190,95,45,255},{220,230,240,255}}
	fill_box(v,{3,1,2},{19,11,23},1)
	fill_box(v,{6,3,4},{16,9,20},0)
	fill_box(v,{15,1,2},{19,3,23},2)
	fill_box(v,{3,9,2},{5,11,23},3)
	for chunk_size in ([3][3]int{{4,3,5},{1,1,1},{8,8,8}}) {
		serial,ok:=surface_chunks(v,colors[:],chunk_size)
		if !testing.expect(t,ok) {destroy_mesh_chunks(&serial);continue}
		for _ in 0..<3 {
			parallel,parallel_ok:=surface_chunks(v,colors[:],chunk_size,pool)
			testing.expect(t,parallel_ok && len(parallel)==len(serial))
			for chunk,index in parallel {
				if index>=len(serial) {break}
				expected:=serial[index]
				testing.expect(t,chunk.coordinate==expected.coordinate && chunk.low==expected.low && chunk.high==expected.high,
					"parallel output keeps serial Z/Y/X ordering and clipped logical bounds")
				testing.expect(t,len(chunk.mesh.vertices)==len(expected.mesh.vertices) && len(chunk.mesh.indices)==len(expected.mesh.indices))
				for vertex,i in chunk.mesh.vertices {testing.expect(t,vertex==expected.mesh.vertices[i],"vertex bytes retain their serial order and values")}
				for value,i in chunk.mesh.indices {testing.expect(t,value==expected.mesh.indices[i],"indices retain their serial order and values")}
			}
			destroy_mesh_chunks(&parallel)
		}
		destroy_mesh_chunks(&serial)
	}
}
