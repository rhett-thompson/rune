package navigation

import "core:math"
import "core:mem"

Surface_Interval_3D :: struct {low,high:f32}

// The interval clip uses parameter-space tolerances for shared-vertex cases.
// Before accepting a route, check actual world-space distance so those tolerances
// cannot bridge a hole when a very long query magnifies a small parameter gap.
surface_point_on_triangle_3d :: proc(mesh:^Mesh_3D,index:i32,point:[3]f32) -> bool {
	face:=mesh.triangles[index]
	vertices:[3][3]f64
	for vertex,i in face.vertices {
		p:=mesh.vertices[vertex];vertices[i]={f64(p.x),f64(p.y),f64(p.z)}
	}
	p:=[3]f64{f64(point.x),f64(point.y),f64(point.z)}
	a,b,c:=vertices[0],vertices[1],vertices[2]
	ab,ac:=b-a,c-a
	n:=[3]f64{ab.y*ac.z-ab.z*ac.y,ab.z*ac.x-ab.x*ac.z,ab.x*ac.y-ab.y*ac.x}
	d:=p-a
	plane:=n.x*d.x+n.y*d.y+n.z*d.z
	normal_squared:=n.x*n.x+n.y*n.y+n.z*n.z
	tolerance_squared:f64=1e-8
	if plane*plane>tolerance_squared*normal_squared {return false}
	projected:=p-n*(plane/normal_squared)
	positive,negative:=true,true
	for edge in 0..<3 {
		u,v:=vertices[edge],vertices[(edge+1)%3]
		area:=(v.x-u.x)*(projected.z-u.z)-(v.z-u.z)*(projected.x-u.x)
		positive=positive && area>=0;negative=negative && area<=0
	}
	if positive || negative {return true}
	for edge in 0..<3 {
		u,v:=vertices[edge],vertices[(edge+1)%3]
		travel,offset:=v-u,p-u
		length_squared:=travel.x*travel.x+travel.y*travel.y+travel.z*travel.z
		fraction:=math.clamp((offset.x*travel.x+offset.y*travel.y+offset.z*travel.z)/length_squared,0,1)
		distance:=offset-travel*fraction
		if distance.x*distance.x+distance.y*distance.y+distance.z*distance.z<=tolerance_squared {return true}
	}
	return false
}

// Clip a straight XZ leg to one triangle, accepting either face winding.
surface_triangle_interval_3d :: proc(mesh:^Mesh_3D,index:i32,a,b:[3]f32) -> (Surface_Interval_3D,bool) {
	triangle:=mesh.triangles[index]
	interval:=Surface_Interval_3D{0,1}
	for edge in 0..<3 {
		u,v:=mesh.vertices[triangle.vertices[edge]],mesh.vertices[triangle.vertices[(edge+1)%3]]
		sign:f32=1 if area_xz(u,v,triangle.center)>0 else -1
		origin:=area_xz(u,v,a)*sign;delta:=(area_xz(u,v,b)-area_xz(u,v,a))*sign
		if abs(delta)<1e-8 {if origin < -1e-5 {return {},false};continue}
		crossing:=-origin/delta
		if delta>0 {interval.low=max(interval.low,crossing)} else {interval.high=min(interval.high,crossing)}
		if interval.low>interval.high+1e-5 {return {},false}
	}
	return interval,interval.high>=-1e-5 && interval.low<=1+1e-5
}

// Trace projected endpoints through actual shared edges before selecting an
// approximate A* corridor. Neighbor-only traversal preserves distinct floors,
// holes and blocked/slope boundaries, even when their XZ projections overlap.
// Each crossing retains the surface height and one segment per triangle.
surface_direct_path_3d :: proc(mesh:^Mesh_3D,a,b:[3]f32,start,goal:i32,max_slope:f32,allocator:mem.Allocator) -> Path_3D {
	scratch:=context.temp_allocator
	count:=len(mesh.triangles)
	intervals:=make([]Surface_Interval_3D,count,scratch)
	valid:=make([]bool,count,scratch)
	arrival:=make([]f32,count,scratch);parents:=make([]i32,count,scratch)
	for i in 0..<count {
		arrival[i]=3.402823e38;parents[i]=-1
		if triangle_allowed_3d(mesh,i32(i),max_slope) {intervals[i],valid[i]=surface_triangle_interval_3d(mesh,i32(i),a,b)}
	}
	queue:=make([dynamic]i32,scratch);append(&queue,start);arrival[start]=0
	for cursor:=0;cursor<len(queue);cursor+=1 {
		current:=queue[cursor]
		if current==goal {break}
		for neighbor in mesh.triangles[current].neighbors {
			if neighbor<0 || !valid[neighbor] {continue}
			entry:=max(arrival[current],intervals[current].low,intervals[neighbor].low)
			if entry>min(intervals[current].high,intervals[neighbor].high)+1e-5 || entry>=arrival[neighbor]-1e-6 {continue}
			arrival[neighbor]=entry;parents[neighbor]=current;append(&queue,neighbor)
		}
	}
	if arrival[goal]>1+1e-5 {return {status=.Unreachable}}
	reversed:=make([dynamic]i32,scratch)
	for cursor:=goal;cursor>=0;cursor=parents[cursor] {append(&reversed,cursor)}
	path:=Path_3D{status=.Complete,points=make([][3]f32,len(reversed)+1,allocator),triangles=make([]i32,len(reversed),allocator)}
	path.points[0]=a;path.points[len(path.points)-1]=b
	for triangle,i in reversed {
		destination:=len(reversed)-1-i;path.triangles[destination]=triangle
		if destination>0 {
			p:=a+(b-a)*math.clamp(arrival[triangle],0,1)
			face:=mesh.triangles[triangle];v:=mesh.vertices[face.vertices[0]]
			p.y=v.y-(face.normal.x*(p.x-v.x)+face.normal.z*(p.z-v.z))/face.normal.y
			path.points[destination]=p
		}
	}
	for triangle,i in path.triangles {
		if !surface_point_on_triangle_3d(mesh,triangle,path.points[i]) ||
		   !surface_point_on_triangle_3d(mesh,triangle,path.points[i+1]) {
			delete(path.points,allocator);delete(path.triangles,allocator)
			return {status=.Unreachable}
		}
	}
	return path
}
