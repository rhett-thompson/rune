package navigation

import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:os"

// Geometry is a walkable center surface in world space, already inset from
// obstacles for the declared radius and checked for the declared headroom.
Mesh_Data_3D :: struct {
	version: int,
	agent_radius, agent_height: f32,
	vertices: [][3]f32,
	triangles: [][3]i32,
}
Triangle_3D :: struct {
	vertices: [3]i32,
	neighbors: [3]i32,
	center, normal: [3]f32,
	blocked: bool,
}
Mesh_3D :: struct {
	vertices: [][3]f32,
	triangles: []Triangle_3D,
	agent_radius, agent_height: f32,
}
Edge_3D :: struct {a,b: i32}
Edge_Owner_3D :: struct {triangle,edge: i32, paired: bool}

finite_3d :: proc(value: f32) -> bool {return !math.is_nan(value) && !math.is_inf(value)}
finite_point_3d :: proc(value: [3]f32) -> bool {return finite_3d(value.x) && finite_3d(value.y) && finite_3d(value.z)}
dot_3d :: proc(a,b: [3]f32) -> f32 {return a.x*b.x+a.y*b.y+a.z*b.z}
cross_3d :: proc(a,b: [3]f32) -> [3]f32 {return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}}
length_3d :: proc(a: [3]f32) -> f32 {return math.sqrt(dot_3d(a,a))}
distance_3d :: proc(a,b: [3]f32) -> f32 {return length_3d(a-b)}
area_xz :: proc(a,b,c: [3]f32) -> f32 {return (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)}

destroy_mesh_3d :: proc(mesh: ^Mesh_3D) {delete(mesh.vertices); delete(mesh.triangles); mesh^ = {}}

build_mesh_3d :: proc(data: Mesh_Data_3D) -> (Mesh_3D, string) {
	if data.version != 1 {return {}, "navmesh version must be 1"}
	if !finite_3d(data.agent_radius) || !finite_3d(data.agent_height) || data.agent_radius < 0 || data.agent_height <= 0 {return {}, "invalid baked agent clearance"}
	if len(data.vertices) < 3 || len(data.vertices) > 131072 || len(data.triangles) == 0 || len(data.triangles) > 65536 {return {}, "navmesh needs 3-131072 vertices and 1-65536 triangles"}
	mesh := Mesh_3D{agent_radius=data.agent_radius,agent_height=data.agent_height,
		vertices=make([][3]f32,len(data.vertices)),triangles=make([]Triangle_3D,len(data.triangles))}
	success := false
	defer if !success {destroy_mesh_3d(&mesh)}
	copy(mesh.vertices,data.vertices)
	for p in mesh.vertices {if !finite_point_3d(p) || abs(p.x)>1e6 || abs(p.y)>1e6 || abs(p.z)>1e6 {return {}, "invalid or excessively large navmesh vertex"}}
	edges := make(map[Edge_3D]Edge_Owner_3D,context.temp_allocator)
	unique := make(map[[3]i32]bool,context.temp_allocator)
	for indices,i in data.triangles {
		for index in indices {if index < 0 || int(index) >= len(mesh.vertices) {return {}, "triangle vertex index out of range"}}
		sorted := indices
		if sorted[0]>sorted[1] {sorted[0],sorted[1]=sorted[1],sorted[0]}
		if sorted[1]>sorted[2] {sorted[1],sorted[2]=sorted[2],sorted[1]}
		if sorted[0]>sorted[1] {sorted[0],sorted[1]=sorted[1],sorted[0]}
		if unique[sorted] {return {}, "duplicate navmesh triangle"}; unique[sorted]=true
		a,b,c := mesh.vertices[indices[0]],mesh.vertices[indices[1]],mesh.vertices[indices[2]]
		n := cross_3d(b-a,c-a)
		length := length_3d(n)
		if length < 1e-6 || abs(n.y) < 1e-6 {return {}, "degenerate or vertical navmesh triangle"}
		n /= length
		if n.y < 0 {n = -n}
		mesh.triangles[i] = Triangle_3D{vertices=indices,neighbors={-1,-1,-1},center=(a+b+c)/3,normal=n}
		for e in 0..<3 {
			u,v := indices[e],indices[(e+1)%3]
			key := Edge_3D{min(u,v),max(u,v)}
			owner, exists := edges[key]
			if exists {
				if owner.paired {return {}, "non-manifold edge belongs to more than two triangles"}
				// Adjacent walkable faces must occupy opposite sides of a shared
				// edge in XZ. Same-side faces would create overlapping shortcuts.
				start,end := mesh.vertices[u],mesh.vertices[v]
				if area_xz(start,end,mesh.triangles[owner.triangle].center)*area_xz(start,end,mesh.triangles[i].center)>=0 {return {},"overlapping triangles share an edge"}
				mesh.triangles[i].neighbors[e] = owner.triangle
				mesh.triangles[owner.triangle].neighbors[owner.edge] = i32(i)
				owner.paired = true; edges[key] = owner
			} else {edges[key] = Edge_Owner_3D{i32(i),i32(e),false}}
		}
	}
	success = true
	return mesh,""
}

load_mesh_3d :: proc(path: string) -> (Mesh_3D,string) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)
	bytes,err := os.read_entire_file(path,a)
	if err != nil {return {},"could not read navmesh file"}
	value: json.Value
	if json.unmarshal(bytes,&value,allocator=a) != nil {return {},"invalid navmesh JSON"}
	object,ok := value.(json.Object)
	if !ok {return {},"navmesh must be an object"}
	for key in object {
		if key!="$schema" && key!="version" && key!="agent_radius" && key!="agent_height" && key!="vertices" && key!="triangles" {return {},"unknown navmesh field"}
	}
	for key in ([]string{"version","agent_radius","agent_height","vertices","triangles"}) {if _,exists:=object[key]; !exists {return {},"missing navmesh field"}}
	data: Mesh_Data_3D
	if json.unmarshal(bytes,&data,allocator=a) != nil {return {},"invalid navmesh field type"}
	return build_mesh_3d(data)
}

triangle_allowed_3d :: proc(mesh: ^Mesh_3D,index: i32,max_slope: f32) -> bool {
	return index>=0 && int(index)<len(mesh.triangles) && !mesh.triangles[index].blocked &&
		mesh.triangles[index].normal.y >= math.cos(max_slope*math.PI/180)-1e-6
}
inside_triangle_3d :: proc(p,a,b,c: [3]f32) -> bool {
	u,v,w := area_xz(a,b,p),area_xz(b,c,p),area_xz(c,a,p)
	return (u>=-1e-5 && v>=-1e-5 && w>=-1e-5) || (u<=1e-5 && v<=1e-5 && w<=1e-5)
}
closest_segment_3d :: proc(p,a,b: [3]f32) -> [3]f32 {
	ab := b-a
	d := dot_3d(ab,ab)
	if d <= 1e-12 {return a}
	return a+ab*math.clamp(dot_3d(p-a,ab)/d,0,1)
}
closest_triangle_3d :: proc(mesh: ^Mesh_3D,index: i32,p: [3]f32) -> [3]f32 {
	t := mesh.triangles[index]
	a,b,c := mesh.vertices[t.vertices[0]],mesh.vertices[t.vertices[1]],mesh.vertices[t.vertices[2]]
	projected := p-t.normal*dot_3d(p-a,t.normal)
	if inside_triangle_3d(projected,a,b,c) {return projected}
	best := closest_segment_3d(p,a,b)
	for candidate in ([2][3]f32{closest_segment_3d(p,b,c),closest_segment_3d(p,c,a)}) {
		if distance_3d(candidate,p)<distance_3d(best,p) {best=candidate}
	}
	return best
}

// Nearest by full XYZ distance, so overlapping floors remain distinct.
project_point_3d :: proc(mesh: ^Mesh_3D,point: [3]f32,max_distance: f32,max_slope: f32 = 45) -> ([3]f32,i32,bool) {
	if !finite_point_3d(point) || !finite_3d(max_distance) || max_distance<0 || !finite_3d(max_slope) || max_slope<0 || max_slope>=89 {return {},-1,false}
	best := max_distance; result: [3]f32; index: i32 = -1
	for _,i in mesh.triangles {
		if !triangle_allowed_3d(mesh,i32(i),max_slope) {continue}
		p := closest_triangle_3d(mesh,i32(i),point)
		d := distance_3d(p,point)
		if d <= best && (index<0 || d<best-1e-6) {best=d; result=p; index=i32(i)}
	}
	return result,index,index>=0
}

raycast_mesh_3d :: proc(mesh: ^Mesh_3D,origin,translation: [3]f32,max_slope: f32 = 45) -> ([3]f32,i32,bool) {
	if !finite_point_3d(origin) || !finite_point_3d(translation) || !finite_3d(max_slope) || max_slope<0 || max_slope>=89 {return {},-1,false}
	best: f32 = 1; index: i32 = -1; result: [3]f32
	for t,i in mesh.triangles {
		if !triangle_allowed_3d(mesh,i32(i),max_slope) {continue}
		denominator := dot_3d(translation,t.normal)
		if abs(denominator)<1e-7 {continue}
		a,b,c := mesh.vertices[t.vertices[0]],mesh.vertices[t.vertices[1]],mesh.vertices[t.vertices[2]]
		fraction := dot_3d(a-origin,t.normal)/denominator
		if fraction<0 || fraction>best {continue}
		p := origin+translation*fraction
		if inside_triangle_3d(p,a,b,c) {best=fraction; result=p; index=i32(i)}
	}
	return result,index,index>=0
}
