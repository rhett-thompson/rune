package navigation

import "core:math"
import "rune:terrain"

// Same scale, X/Y/Z Euler rotation, then translation convention as Rune 3D.
bake_transform_point_3d :: proc(p,position,rotation,scale: [3]f32) -> [3]f32 {
	q:=p*scale
	r:=rotation*(math.PI/180)
	cx,sx:=math.cos(r.x),math.sin(r.x);cy,sy:=math.cos(r.y),math.sin(r.y);cz,sz:=math.cos(r.z),math.sin(r.z)
	q={q.x,q.y*cx-q.z*sx,q.y*sx+q.z*cx}
	q={q.x*cy+q.z*sy,q.y,-q.x*sy+q.z*cy}
	q={q.x*cz-q.y*sz,q.x*sz+q.y*cz,q.z}
	return q+position
}
bake_transform_valid_3d :: proc(position,rotation,scale:[3]f32) -> bool {
	return finite_point_3d(position) && finite_point_3d(rotation) && finite_point_3d(scale) && scale.x>0 && scale.y>0 && scale.z>0
}

// Append arbitrary indexed model/procedural triangles. The caller retains its
// input. Reflections must be applied by the exporter with winding corrected.
append_bake_triangles_3d :: proc(g:^Bake_Geometry_3D,vertices:[][3]f32,triangles:[][3]i32,
	position: [3]f32={}, rotation: [3]f32={}, scale: [3]f32={1,1,1}, obstacle:=false, solid:=false) -> bool {
	if !bake_transform_valid_3d(position,rotation,scale) || len(g.vertices)+len(vertices)>6000000 || len(g.triangles)+len(triangles)>2000000 {return false}
	for p in vertices {if !finite_point_3d(p) || !finite_point_3d(bake_transform_point_3d(p,position,rotation,scale)) {return false}}
	for t in triangles {for i in t {if i<0 || int(i)>=len(vertices) {return false}}}
	base:=i32(len(g.vertices))
	volume:=Bake_Solid_3D{first=len(g.triangles),last=len(g.triangles)+len(triangles),low={1e9,1e9,1e9},high={-1e9,-1e9,-1e9}}
	for p in vertices {append(&g.vertices,bake_transform_point_3d(p,position,rotation,scale))}
	if solid {
		for p in g.vertices[base:] {for axis in 0..<3 {volume.low[axis]=min(volume.low[axis],p[axis]);volume.high[axis]=max(volume.high[axis],p[axis])}}
		append(&g.solids,volume)
	}
	if obstacle && g.obstacle_triangles==nil {g.obstacle_triangles=make(map[int]bool)}
	for t in triangles {if obstacle {g.obstacle_triangles[len(g.triangles)]=true};append(&g.triangles,t+[3]i32{base,base,base})}
	return true
}

append_bake_box_3d :: proc(g:^Bake_Geometry_3D,size:[3]f32,position:[3]f32={},rotation:[3]f32={},scale:[3]f32={1,1,1},obstacle:=false) -> bool {
	if !finite_point_3d(size) || size.x<=0 || size.y<=0 || size.z<=0 {return false}
	h:=size*0.5
	vertices:=[8][3]f32{{-h.x,-h.y,-h.z},{h.x,-h.y,-h.z},{h.x,-h.y,h.z},{-h.x,-h.y,h.z},
		{-h.x,h.y,-h.z},{h.x,h.y,-h.z},{h.x,h.y,h.z},{-h.x,h.y,h.z}}
	triangles:=[12][3]i32{{0,1,2},{0,2,3},{4,6,5},{4,7,6},{0,5,1},{0,4,5},
		{1,6,2},{1,5,6},{2,7,3},{2,6,7},{3,4,0},{3,7,4}}
	return append_bake_triangles_3d(g,vertices[:],triangles[:],position,rotation,scale,obstacle,solid=true)
}

// Uses exactly the terrain renderer/collider topology, including rectangular
// heightmaps and chunk seams. Sampling density is chosen later by cell_size.
append_bake_terrain_3d :: proc(g:^Bake_Geometry_3D,data:terrain.Data,
	position:[3]f32={},rotation:[3]f32={},scale:[3]f32={1,1,1}) -> bool {
	w,h:=data.description.resolution[0],data.description.resolution[1]
	if w<2 || h<2 || w>513 || h>513 || len(data.heights)!=w*h ||
		!finite_3d(data.description.size[0]) || !finite_3d(data.description.size[1]) ||
		data.description.size[0]<=0 || data.description.size[1]<=0 {return false}
	vertices:=make([][3]f32,w*h);defer delete(vertices)
	triangles:=make([][3]i32,(w-1)*(h-1)*2);defer delete(triangles)
	for z in 0..<h {for x in 0..<w {vertices[z*w+x]=terrain.position(data,x,z)}}
	i:=0
	for z in 0..<h-1 {for x in 0..<w-1 {
		indices:=terrain.cell_indices(x,z,w)
		triangles[i]={i32(indices[0]),i32(indices[1]),i32(indices[2])}
		triangles[i+1]={i32(indices[3]),i32(indices[4]),i32(indices[5])};i+=2
	}}
	return append_bake_triangles_3d(g,vertices,triangles,position,rotation,scale)
}
