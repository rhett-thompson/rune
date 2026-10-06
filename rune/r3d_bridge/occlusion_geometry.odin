package r3d_bridge

import "core:math/linalg"
import "rune:geometry"

// A bounded selection of actual opaque triangles/convex planar quads. Bounds
// alone must never act as occluders: they could cover doors or empty space.
Occlusion_Faces_Per_Mesh :: 32
Occlusion_Face :: struct {
	points: [4][3]f32,
	count: int,
	area_squared: f32,
}

occlusion_triangle :: proc(mesh:geometry.Mesh,start:int) -> (Occlusion_Face,bool) {
	face:=Occlusion_Face{count=3}
	for j in 0..<3 {
		v:=mesh.vertices[mesh.indices[start+j]]
		if v.color[3]!=255 {return {},false}
		face.points[j]=v.position
	}
	normal:=linalg.cross(face.points[1]-face.points[0],face.points[2]-face.points[0])
	face.area_squared=linalg.dot(normal,normal)
	return face,face.area_squared>0
}

// Merge only two triangles with an exactly shared, oppositely wound edge.
// Exact coplanarity and convexity keep the polygon inside the real surface.
occlusion_quad :: proc(a,b:Occlusion_Face) -> (Occlusion_Face,bool) {
	for e in 0..<3 {for f in 0..<3 {
		if a.points[e]!=b.points[(f+1)%3] || a.points[(e+1)%3]!=b.points[f] {continue}
		face:=Occlusion_Face{count=4,points={a.points[(e+1)%3],a.points[(e+2)%3],a.points[e],b.points[(f+2)%3]}}
		normal:=linalg.cross(face.points[1]-face.points[0],face.points[2]-face.points[0])
		if linalg.dot(normal,face.points[3]-face.points[0])!=0 {continue}
		convex:=true
		for i in 0..<4 {
			turn:=linalg.cross(face.points[(i+1)%4]-face.points[i],face.points[(i+2)%4]-face.points[(i+1)%4])
			if !(linalg.dot(normal,turn)>0) {convex=false}
		}
		if !convex {continue}
		face.area_squared=(a.area_squared+b.area_squared)*2
		return face,true
	}}
	return {},false
}

extract_occlusion_faces :: proc(mesh:geometry.Mesh) -> []Occlusion_Face {
	selected:[Occlusion_Faces_Per_Mesh]Occlusion_Face
	count:=0
	for i:=0; i+2<len(mesh.indices); {
		face,valid:=occlusion_triangle(mesh,i)
		i+=3
		if !valid {continue}
		if i+2<len(mesh.indices) {
			second,ok:=occlusion_triangle(mesh,i)
			if ok {if quad,merged:=occlusion_quad(face,second); merged {face=quad; i+=3}}
		}
		// Largest first; bounded storage and work even for very detailed meshes.
		position:=count
		for j in 0..<count {if face.area_squared>selected[j].area_squared {position=j; break}}
		if position==len(selected) {continue}
		count=min(count+1,len(selected))
		for j:=count-1; j>position; j-=1 {selected[j]=selected[j-1]}
		selected[position]=face
	}
	if count==0 {return nil}
	result:=make([]Occlusion_Face,count)
	copy(result,selected[:count])
	return result
}
