package navigation

import "core:math"

Path_Status_3D :: enum {Invalid, Complete, Start_Off_Mesh, Goal_Off_Mesh, Unreachable, Insufficient_Clearance}
Path_Options_3D :: struct {
	radius, height: f32,
	max_slope: f32,
	max_projection: f32,
}
Default_Path_Options_3D :: Path_Options_3D{radius=0.3,height=1.8,max_slope=45,max_projection=1}
default_path_options_3d :: proc() -> Path_Options_3D {return Default_Path_Options_3D}
Path_3D :: struct {
	status: Path_Status_3D,
	// Includes every surface crossing; points[i] to points[i+1] follows triangles[i].
	points: [][3]f32,
	triangles: []i32,
}
destroy_path_3d :: proc(path: ^Path_3D) {delete(path.points); delete(path.triangles); path^ = {}}

Heap_Node_3D :: struct {triangle:i32, score:f32}
heap_push_3d :: proc(heap: ^[dynamic]Heap_Node_3D,node: Heap_Node_3D) {
	append(heap,node)
	i := len(heap^)-1
	for i>0 {p:=(i-1)/2; if heap^[p].score<=heap^[i].score {break}; heap^[p],heap^[i]=heap^[i],heap^[p]; i=p}
}
heap_pop_3d :: proc(heap: ^[dynamic]Heap_Node_3D) -> Heap_Node_3D {
	result := heap^[0]
	heap^[0]=heap^[len(heap^)-1]; pop(heap)
	i:=0
	for {l:=2*i+1; if l>=len(heap^) {break}; r:=l+1; best:=l
		if r<len(heap^) && heap^[r].score<heap^[l].score {best=r}
		if heap^[i].score<=heap^[best].score {break}; heap^[i],heap^[best]=heap^[best],heap^[i]; i=best}
	return result
}

Portal_3D :: struct {left,right:[3]f32}

funnel_area_xz_3d :: proc(a,b,c:[3]f32) -> f64 {
	return (f64(b.x)-f64(a.x))*(f64(c.z)-f64(a.z))-(f64(b.z)-f64(a.z))*(f64(c.x)-f64(a.x))
}

same_point_xz_3d :: proc(a,b:[3]f32) -> bool {
	d:=a-b
	return d.x*d.x+d.z*d.z<=1e-12
}

// Intersect a straight funnel leg with a portal in XZ, then interpolate the
// portal's actual height. Keeping every crossing preserves the surface at
// ramp seams and the one-segment-per-triangle path contract.
portal_crossing_3d :: proc(start,end:[3]f32,portal:Portal_3D) -> [3]f32 {
	dx,dz:=f64(end.x)-f64(start.x),f64(end.z)-f64(start.z)
	ex,ez:=f64(portal.right.x)-f64(portal.left.x),f64(portal.right.z)-f64(portal.left.z)
	ax,az:=f64(portal.left.x)-f64(start.x),f64(portal.left.z)-f64(start.z)
	denominator:=dx*ez-dz*ex
	fraction:f64
	if abs(denominator)>1e-12 {
		fraction=(ax*dz-az*dx)/denominator
	} else {
		// A leg can lie along a portal or pass through several portals at a
		// shared vertex. Choose the first crossing from the leg's start.
		length_squared:=ex*ex+ez*ez
		if length_squared>0 {fraction=-(ax*ex+az*ez)/length_squared}
	}
	return portal.left+(portal.right-portal.left)*f32(math.clamp(fraction,0,1))
}

write_funnel_leg_3d :: proc(points:[][3]f32,portals:[]Portal_3D,start,end:[3]f32,first,last:int) {
	for i in first+1..<last {points[i]=portal_crossing_3d(start,end,portals[i])}
	points[last]=end
}

// Pull the corridor tight in XZ. Portal orientation comes from the current
// triangle's side of the edge, so either authored triangle winding works.
smooth_corridor_3d :: proc(mesh:^Mesh_3D,path:^Path_3D) {
	portals:=make([]Portal_3D,len(path.points),context.temp_allocator)
	portals[0]={path.points[0],path.points[0]}
	portals[len(portals)-1]={path.points[len(path.points)-1],path.points[len(path.points)-1]}
	for i in 0..<len(path.triangles)-1 {
		t:=mesh.triangles[path.triangles[i]]
		for neighbor,e in t.neighbors {
			if neighbor!=path.triangles[i+1] {continue}
			a,b:=mesh.vertices[t.vertices[e]],mesh.vertices[t.vertices[(e+1)%3]]
			if funnel_area_xz_3d(a,b,t.center)>0 {a,b=b,a}
			portals[i+1]={a,b}
			break
		}
	}
	// Projection can choose either face when the start lies on a shared edge.
	// Crossing that edge costs no travel. Using its opposed endpoints as the
	// initial funnel rays would produce a 180-degree cone whose signed areas
	// are zero, incorrectly turning toward an endpoint on the next portal.
	first:=0
	for first+1<len(portals)-1 {
		portal:=portals[first+1]
		if distance_3d(closest_segment_3d(path.points[0],portal.left,portal.right),path.points[0])>1e-6 {break}
		first+=1;path.points[first]=path.points[0]
	}
	apex,left,right:=portals[0].left,portals[0].left,portals[0].right
	apex_index,left_index,right_index:=first,first,first
	for i:=first+1;i<len(portals); {
		new_left,new_right:=portals[i].left,portals[i].right
		if funnel_area_xz_3d(apex,right,new_right)>=0 {
			if same_point_xz_3d(apex,right) || funnel_area_xz_3d(apex,left,new_right)<0 {
				right=new_right;right_index=i
			} else {
				write_funnel_leg_3d(path.points,portals,apex,left,apex_index,left_index)
				apex=left;apex_index=left_index
				left,right=apex,apex;left_index,right_index=apex_index,apex_index
				i=apex_index+1;continue
			}
		}
		if funnel_area_xz_3d(apex,left,new_left)<=0 {
			if same_point_xz_3d(apex,left) || funnel_area_xz_3d(apex,right,new_left)>0 {
				left=new_left;left_index=i
			} else {
				write_funnel_leg_3d(path.points,portals,apex,right,apex_index,right_index)
				apex=right;apex_index=right_index
				left,right=apex,apex;left_index,right_index=apex_index,apex_index
				i=apex_index+1;continue
			}
		}
		i+=1
	}
	if apex_index<len(portals)-1 {
		write_funnel_leg_3d(path.points,portals,apex,portals[len(portals)-1].left,apex_index,len(portals)-1)
	}
}

// A* selects connected triangles, then a funnel straightens their corridor.
// Consecutive points lie in one convex triangle, including on ramps.
// Returned arrays belong to allocator. No partial paths are reported complete.
find_path_3d :: proc(mesh: ^Mesh_3D,start,goal: [3]f32,options := Default_Path_Options_3D,allocator := context.allocator) -> Path_3D {
	if !finite_3d(options.radius) || !finite_3d(options.height) || options.radius<0 || options.height<=0 ||
	   !finite_3d(options.max_projection) || options.max_projection<0 || !finite_3d(options.max_slope) || options.max_slope<0 || options.max_slope>=89 ||
	   !finite_point_3d(start) || !finite_point_3d(goal) {return {status=.Invalid}}
	if options.radius>mesh.agent_radius+1e-6 || options.height>mesh.agent_height+1e-6 {return {status=.Insufficient_Clearance}}
	s,si,start_ok := project_point_3d(mesh,start,options.max_projection,options.max_slope)
	if !start_ok {return {status=.Start_Off_Mesh}}
	g,gi,goal_ok := project_point_3d(mesh,goal,options.max_projection,options.max_slope)
	if !goal_ok {return {status=.Goal_Off_Mesh}}
	count := len(mesh.triangles)
	scores := make([]f32,count,context.temp_allocator)
	parents := make([]i32,count,context.temp_allocator)
	closed := make([]bool,count,context.temp_allocator)
	for i in 0..<count {scores[i]=3.402823e38; parents[i]=-1}
	heap := make([dynamic]Heap_Node_3D,context.temp_allocator)
	scores[si]=0
	heap_push_3d(&heap,{si,0})
	for len(heap)>0 {
		current := heap_pop_3d(&heap).triangle
		if closed[current] {continue}
		closed[current]=true
		if current==gi {break}
		for neighbor in mesh.triangles[current].neighbors {
			if !triangle_allowed_3d(mesh,neighbor,options.max_slope) || closed[neighbor] {continue}
			score := scores[current]+distance_3d(mesh.triangles[current].center,mesh.triangles[neighbor].center)
			if score<scores[neighbor] {scores[neighbor]=score; parents[neighbor]=current
				heap_push_3d(&heap,{neighbor,score+distance_3d(mesh.triangles[neighbor].center,mesh.triangles[gi].center)})}
		}
	}
	if !closed[gi] {return {status=.Unreachable}}
	reversed := make([dynamic]i32,context.temp_allocator)
	for cursor:=gi; cursor>=0; cursor=parents[cursor] {append(&reversed,cursor); if cursor==si {break}}
	path := Path_3D{status=.Complete,triangles=make([]i32,len(reversed),allocator),points=make([][3]f32,len(reversed)+1,allocator)}
	for t,i in reversed {path.triangles[len(reversed)-1-i]=t}
	path.points[0]=s; path.points[len(path.points)-1]=g
	smooth_corridor_3d(mesh,&path)
	return path
}
