package navigation

import "core:mem"

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

// The corridor uses shared-edge midpoints. Consecutive points lie in one
// convex triangle, so every segment stays on the surface, including ramps.
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
	for i in 0..<len(path.triangles)-1 {
		t := mesh.triangles[path.triangles[i]]
		for neighbor,e in t.neighbors {if neighbor==path.triangles[i+1] {path.points[i+1]=(mesh.vertices[t.vertices[e]]+mesh.vertices[t.vertices[(e+1)%3]])/2; break}}
	}
	return path
}
