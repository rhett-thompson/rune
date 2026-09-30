// Finite voxel surface extraction. Zero is empty; other values index colors.
// All exposed coplanar faces of the same value are greedily merged.
package geometry

import "core:math/linalg"

Vertex :: struct {
	position, normal: [3]f32,
	color: [4]u8,
}
Mesh :: struct {
	vertices: [dynamic]Vertex,
	indices: [dynamic]u32,
}
Volume :: struct {
	size: [3]int,
	cells: []u8,
	origin: [3]f32,
	spacing: f32,
}

destroy_mesh :: proc(mesh: ^Mesh) {
	delete(mesh.vertices); delete(mesh.indices); mesh^ = {}
}

cell :: proc(volume: Volume, p: [3]int) -> u8 {
	for i in 0..<3 {if p[i] < 0 || p[i] >= volume.size[i] {return 0}}
	return volume.cells[p[0]+volume.size[0]*(p[1]+volume.size[1]*p[2])]
}

// Coordinates use half-open voxel bounds. Boxes are clipped to the volume.
fill_box :: proc(volume: Volume, low, high: [3]int, value: u8) {
	for z in max(0,low[2])..<min(volume.size[2],high[2]) {
		for y in max(0,low[1])..<min(volume.size[1],high[1]) {
			for x in max(0,low[0])..<min(volume.size[0],high[0]) {
				volume.cells[x+volume.size[0]*(y+volume.size[1]*z)] = value
			}
		}
	}
}

surface :: proc(volume: Volume, colors: [] [4]u8) -> (Mesh, bool) {
	if !(volume.spacing > 0 && volume.spacing <= 1e6) {return {},false}
	count := 1
	for n in volume.size {if n <= 0 || n > 1024 {return {},false}; count *= n}
	if count > 134217728 || len(volume.cells) != count {return {},false}
	low:=volume.size
	high:=[3]int{}
	strides:=[3]int{1,volume.size[0],volume.size[0]*volume.size[1]}
	for value,index in volume.cells {
		if int(value)>=len(colors) {return {},false}
		if value==0 {continue}
		p:=[3]int{index%volume.size[0],(index/volume.size[0])%volume.size[1],index/strides[2]}
		for axis in 0..<3 {low[axis]=min(low[axis],p[axis]); high[axis]=max(high[axis],p[axis]+1)}
	}
	if high[0]==0 {return {},false}
	mesh: Mesh
	for axis in 0..<3 {
		u,v := (axis+1)%3,(axis+2)%3
		w,h := high[u]-low[u],high[v]-low[v]
		mask := make([]i16,w*h)
		for plane in low[axis]..=high[axis] {
			// Direct strides avoid repeated 3D bounds/index work in the dense
			// scan. The occupied bounds guarantee empty cells outside this box.
			for j in 0..<h {
				index:=plane*strides[axis]+low[u]*strides[u]+(j+low[v])*strides[v]
				for i in 0..<w {
					a,b: u8
					if plane>low[axis] {a=volume.cells[index-strides[axis]]}
					if plane<high[axis] {b=volume.cells[index]}
					mask[i+j*w] = i16(a) if a != 0 && b == 0 else (-i16(b) if b != 0 && a == 0 else 0)
					index+=strides[u]
				}
			}
			for j in 0..<h {
				i := 0
				for i < w {
					value := mask[i+j*w]
					if value == 0 {i += 1; continue}
					rw := 1
					for i+rw < w && mask[i+rw+j*w] == value {rw += 1}
					rh := 1
					grow: for j+rh < h {
						for k in 0..<rw {if mask[i+k+(j+rh)*w] != value {break grow}}
						rh += 1
					}
					p,du,dv: [3]f32
					p[axis],p[u],p[v] = f32(plane),f32(i+low[u]),f32(j+low[v])
					du[u],dv[v] = f32(rw),f32(rh)
					normal: [3]f32; normal[axis] = 1 if value > 0 else -1
					color := colors[int(value if value > 0 else -value)]
					base := u32(len(mesh.vertices))
					for q in ([4][3]f32{p,p+du,p+du+dv,p+dv}) {
						append(&mesh.vertices,Vertex{volume.origin+q*volume.spacing,normal,color})
					}
					if value > 0 {append(&mesh.indices,base,base+1,base+2,base,base+2,base+3)}
					else {append(&mesh.indices,base,base+2,base+1,base,base+3,base+2)}
					for y in 0..<rh {for x in 0..<rw {mask[i+x+(j+y)*w]=0}}
					i += rw
				}
			}
		}
		delete(mask)
	}
	return mesh,len(mesh.indices)>0
}

valid :: proc(mesh: Mesh) -> bool {
	if len(mesh.vertices)==0 || len(mesh.vertices)>1000000 || len(mesh.indices)==0 || len(mesh.indices)%3!=0 || len(mesh.indices)>6000000 {return false}
	for vertex in mesh.vertices {
		for n in vertex.position {if !(n >= -1e6 && n <= 1e6) {return false}}
		for n in vertex.normal {if !(n >= -1 && n <= 1) {return false}}
		if linalg.dot(vertex.normal,vertex.normal)<0.99 {return false}
	}
	for index in mesh.indices {if int(index)>=len(mesh.vertices) {return false}}
	for i := 0; i < len(mesh.indices); i += 3 {
		a,b,c := mesh.vertices[mesh.indices[i]].position,mesh.vertices[mesh.indices[i+1]].position,mesh.vertices[mesh.indices[i+2]].position
		n := linalg.cross(b-a,c-a)
		if linalg.dot(n,n)<1e-12 {return false}
	}
	return true
}
