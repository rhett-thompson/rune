package navigation

import "core:math"
import "core:mem"

// Clearance is evaluated against the connected walkable surface boundary,
// rather than against every triangle edge. Interior triangulation therefore
// does not prevent a large agent crossing a narrow triangle in a wide room.
Clearance_Edge_3D :: struct {a,b:[3]f32, normal:[3]f32, vertices:[2]i32}
Clearance_Bounds_3D :: struct {low,high:[3]f32}
Clearance_Bounds_Block_Size_3D :: 16
Clearance_Node_3D :: struct {
	point:[3]f32,
	members:[dynamic]i32,
	score:f32,
	parent,via_triangle:i32,
	closed:bool,
}
Clearance_Query_3D :: struct {
	mesh:^Mesh_3D,
	options:Path_Options_3D,
	radius,vertical_range:f32,
	component:[]bool,
	edges:[dynamic]Clearance_Edge_3D,
	edge_bounds,edge_blocks:[]Clearance_Bounds_3D,
	nodes:[dynamic]Clearance_Node_3D,
	triangle_nodes:[][dynamic]i32,
	triangle_bounds:[]Clearance_Bounds_3D,
	triangle_blocks:[]Clearance_Bounds_3D,
	triangle_edges:[][dynamic]Clearance_Edge_3D,
	portals:map[Edge_3D]bool,
	allocator:mem.Allocator,
}
Clearance_Interval_3D :: struct {low,high:f32}

clearance_query_3d :: proc(mesh:^Mesh_3D,options:Path_Options_3D,start:i32,a:=context.temp_allocator) -> Clearance_Query_3D {
	q:=Clearance_Query_3D{mesh=mesh,options=options,allocator=a,
		radius=max(0,options.radius-mesh.agent_radius),
		component=make([]bool,len(mesh.triangles),a),
		edges=make([dynamic]Clearance_Edge_3D,a),
		nodes=make([dynamic]Clearance_Node_3D,a),
		triangle_nodes=make([][dynamic]i32,len(mesh.triangles),a),
		triangle_bounds=make([]Clearance_Bounds_3D,len(mesh.triangles),a),
		triangle_edges=make([][dynamic]Clearance_Edge_3D,len(mesh.triangles),a),
		portals=make(map[Edge_3D]bool,a)}
	q.vertical_range=q.radius*math.tan(options.max_slope*math.PI/180)+0.05
	queue:=make([dynamic]i32,a);append(&queue,start);q.component[start]=true
	for cursor:=0;cursor<len(queue);cursor+=1 {
		for neighbor in mesh.triangles[queue[cursor]].neighbors {
			if !triangle_allowed_3d(mesh,neighbor,options.max_slope) || q.component[neighbor] {continue}
			q.component[neighbor]=true;append(&queue,neighbor)
		}
	}
	for triangle,i in mesh.triangles {
		q.triangle_bounds[i]=clearance_triangle_bounds_3d(mesh,i32(i))
		if !q.component[i] {continue}
		for neighbor,e in triangle.neighbors {
			if neighbor>=0 && q.component[neighbor] {continue}
			a,b:=mesh.vertices[triangle.vertices[e]],mesh.vertices[triangle.vertices[(e+1)%3]]
			d:=b-a;length:=math.sqrt(d.x*d.x+d.z*d.z)
			if length<=1e-6 {continue}
			n:=[3]f32{-d.z/length,0,d.x/length}
			if dot_3d(n,triangle.center-a)<0 {n=-n}
			append(&q.edges,Clearance_Edge_3D{a,b,n,{triangle.vertices[e],triangle.vertices[(e+1)%3]}})
		}
	}
	q.triangle_blocks=clearance_bounds_blocks_3d(q.triangle_bounds,a)
	q.edge_bounds=make([]Clearance_Bounds_3D,len(q.edges),a)
	for edge,i in q.edges {
		q.edge_bounds[i]=Clearance_Bounds_3D{
			{min(edge.a.x,edge.b.x),min(edge.a.y,edge.b.y),min(edge.a.z,edge.b.z)},
			{max(edge.a.x,edge.b.x),max(edge.a.y,edge.b.y),max(edge.a.z,edge.b.z)}}
	}
	q.edge_blocks=clearance_bounds_blocks_3d(q.edge_bounds,a)
	return q
}

// Contiguous blocks preserve triangle and boundary order, including projection
// tie-breaking, while rejecting distant runs before visiting their members.
clearance_bounds_blocks_3d :: proc(bounds:[]Clearance_Bounds_3D,a:mem.Allocator) -> []Clearance_Bounds_3D {
	blocks:=make([]Clearance_Bounds_3D,(len(bounds)+Clearance_Bounds_Block_Size_3D-1)/Clearance_Bounds_Block_Size_3D,a)
	for &block,index in blocks {
		first:=index*Clearance_Bounds_Block_Size_3D;block=bounds[first]
		for i in first+1..<min(first+Clearance_Bounds_Block_Size_3D,len(bounds)) {
			for axis in 0..<3 {
				block.low[axis]=min(block.low[axis],bounds[i].low[axis])
				block.high[axis]=max(block.high[axis],bounds[i].high[axis])
			}
		}
	}
	return blocks
}

clearance_bounds_overlap_3d :: proc(bounds,other:Clearance_Bounds_3D,radius,vertical_range:f32) -> bool {
	return other.low.y<=bounds.high.y+vertical_range && other.high.y>=bounds.low.y-vertical_range &&
		bounds.low.x<=other.high.x+radius && bounds.high.x>=other.low.x-radius &&
		bounds.low.z<=other.high.z+radius && bounds.high.z>=other.low.z-radius
}

clearance_bounds_distance_squared_3d :: proc(bounds:Clearance_Bounds_3D,p:[3]f32) -> f32 {
	d:=[3]f32{max(bounds.low.x-p.x,p.x-bounds.high.x,0),max(bounds.low.y-p.y,p.y-bounds.high.y,0),max(bounds.low.z-p.z,p.z-bounds.high.z,0)}
	return dot_3d(d,d)
}

clearance_triangle_bounds_3d :: proc(mesh:^Mesh_3D,index:i32) -> Clearance_Bounds_3D {
	triangle:=mesh.triangles[index]
	a,b,c:=mesh.vertices[triangle.vertices[0]],mesh.vertices[triangle.vertices[1]],mesh.vertices[triangle.vertices[2]]
	// closest_triangle_3d accepts a small signed-area tolerance. Include that
	// expanded triangle too, so bounds never discard one of its projections.
	tolerance:=2e-5/abs(area_xz(a,b,c))
	bounds:Clearance_Bounds_3D
	for axis in 0..<3 {
		low,high:=min(a[axis],b[axis],c[axis]),max(a[axis],b[axis],c[axis])
		padding:=(high-low)*tolerance+max(abs(low),abs(high))*1e-6+0.0001
		bounds.low[axis]=low-padding;bounds.high[axis]=high+padding
	}
	return bounds
}

// A triangle's portal samples and projected corner nodes stay within its
// bounds. Reuse nearby boundaries for all of its graph connections; the exact
// clearance tests below still decide whether each point or leg is usable.
clearance_triangle_edges_3d :: proc(q:^Clearance_Query_3D,index:i32) -> []Clearance_Edge_3D {
	if q.triangle_edges[index].allocator.procedure!=nil {return q.triangle_edges[index][:]}
	edges:=make([dynamic]Clearance_Edge_3D,0,4,q.allocator)
	bounds:=q.triangle_bounds[index];radius:=q.radius+0.002
	for block,i in q.edge_blocks {
		if !clearance_bounds_overlap_3d(bounds,block,radius,q.vertical_range) {continue}
		first:=i*Clearance_Bounds_Block_Size_3D
		for j in first..<min(first+Clearance_Bounds_Block_Size_3D,len(q.edges)) {
			if clearance_bounds_overlap_3d(bounds,q.edge_bounds[j],radius,q.vertical_range) {append(&edges,q.edges[j])}
		}
	}
	q.triangle_edges[index]=edges
	return edges[:]
}

clearance_closest_xz_3d :: proc(point,a,b:[3]f32) -> [3]f32 {
	d:=b-a;length:=d.x*d.x+d.z*d.z
	if length<=1e-12 {return a}
	t:=math.clamp(((point.x-a.x)*d.x+(point.z-a.z)*d.z)/length,0,1)
	return a+d*t
}
clearance_distance_xz_3d :: proc(a,b:[3]f32) -> f32 {
	d:=a-b;return math.sqrt(d.x*d.x+d.z*d.z)
}
clearance_same_layer_3d :: proc(q:^Clearance_Query_3D,a,b:[3]f32,edge:Clearance_Edge_3D) -> bool {
	return min(edge.a.y,edge.b.y)<=max(a.y,b.y)+q.vertical_range &&
		max(edge.a.y,edge.b.y)>=min(a.y,b.y)-q.vertical_range
}
clearance_point_allowed_3d :: proc(q:^Clearance_Query_3D,p:[3]f32,triangle:i32=-1) -> bool {
	edges:=q.edges[:];if triangle>=0 {edges=clearance_triangle_edges_3d(q,triangle)}
	for edge in edges {
		if !clearance_same_layer_3d(q,p,p,edge) {continue}
		nearest:=clearance_closest_xz_3d(p,edge.a,edge.b)
		if abs(nearest.y-p.y)>q.vertical_range {continue}
		if clearance_distance_xz_3d(nearest,p)<q.radius-0.0001 {return false}
	}
	return true
}

clearance_project_surface_3d :: proc(q:^Clearance_Query_3D,p:[3]f32,max_distance:f32) -> ([3]f32,i32,bool) {
	best:=max_distance;result:[3]f32;index:i32=-1
	for block,i in q.triangle_blocks {
		if clearance_bounds_distance_squared_3d(block,p)>best*best {continue}
		first:=i*Clearance_Bounds_Block_Size_3D
		for j in first..<min(first+Clearance_Bounds_Block_Size_3D,len(q.mesh.triangles)) {
			if !q.component[j] || clearance_bounds_distance_squared_3d(q.triangle_bounds[j],p)>best*best {continue}
			candidate:=closest_triangle_3d(q.mesh,i32(j),p);distance:=distance_3d(candidate,p)
			if distance<=best && (index<0 || distance<best-1e-6) {best=distance;result=candidate;index=i32(j)}
		}
	}
	return result,index,index>=0
}

clearance_project_point_3d :: proc(q:^Clearance_Query_3D,original,point:[3]f32,index:i32) -> ([3]f32,i32,bool) {
	result,triangle:=point,index
	for _ in 0..<24 {
		nearest_edge:i32=-1;nearest_distance:=q.radius;nearest_point:[3]f32
		for edge,i in q.edges {
			if !clearance_same_layer_3d(q,result,result,edge) {continue}
			nearest:=clearance_closest_xz_3d(result,edge.a,edge.b)
			if abs(nearest.y-result.y)>q.vertical_range {continue}
			distance:=clearance_distance_xz_3d(nearest,result)
			if distance<nearest_distance {nearest_distance=distance;nearest_point=nearest;nearest_edge=i32(i)}
		}
		if nearest_edge<0 {return result,triangle,distance_3d(result,original)<=q.options.max_projection+1e-5}
		direction:=(result-nearest_point)/nearest_distance if nearest_distance>1e-6 else q.edges[nearest_edge].normal;direction.y=0
		result+=direction*(q.radius+0.002-nearest_distance)
		projected,projected_triangle,ok:=clearance_project_surface_3d(q,result,q.radius*2+0.1)
		if !ok || distance_3d(projected,original)>q.options.max_projection+1e-5 {return {},-1,false}
		result,triangle=projected,projected_triangle
		if clearance_point_allowed_3d(q,result,triangle) {return result,triangle,true}
	}
	return {},-1,false
}

// Project onto the usable center surface for this agent. The mesh is borrowed;
// projection and path queries never change or bake additional mesh geometry.
project_agent_point_3d :: proc(mesh:^Mesh_3D,point:[3]f32,options:=Default_Path_Options_3D) -> ([3]f32,i32,bool) {
	if !finite_point_3d(point) || !finite_3d(options.radius) || options.radius<0 ||
		!finite_3d(options.height) || options.height<=0 || options.height>mesh.agent_height+1e-6 {return {},-1,false}
	p,index,ok:=project_point_3d(mesh,point,options.max_projection,options.max_slope)
	if !ok || options.radius<=mesh.agent_radius+1e-6 {return p,index,ok}
	q:=clearance_query_3d(mesh,options,index)
	return clearance_project_point_3d(&q,point,p,index)
}

clearance_clip_linear_3d :: proc(interval:^Clearance_Interval_3D,origin,delta,low,high:f32) -> bool {
	if abs(delta)<1e-9 {return origin>=low && origin<=high}
	a,b:=(low-origin)/delta,(high-origin)/delta
	if a>b {a,b=b,a}
	interval.low=max(interval.low,a);interval.high=min(interval.high,b)
	return interval.low<interval.high
}
clearance_circle_interval_3d :: proc(a,b,center:[3]f32,radius:f32) -> (Clearance_Interval_3D,bool) {
	d,p:=b-a,a-center
	length:=d.x*d.x+d.z*d.z
	if length<1e-12 {return {0,1},p.x*p.x+p.z*p.z<radius*radius}
	linear:=p.x*d.x+p.z*d.z
	discriminant:=linear*linear-length*(p.x*p.x+p.z*p.z-radius*radius)
	if discriminant<=0 {return {},false}
	root:=math.sqrt(discriminant)
	interval:=Clearance_Interval_3D{max(0,(-linear-root)/length),min(1,(-linear+root)/length)}
	return interval,interval.low<interval.high
}
clearance_subtract_interval_3d :: proc(intervals:^[dynamic]Clearance_Interval_3D,remove:Clearance_Interval_3D,a:mem.Allocator) {
	if remove.high<=0 || remove.low>=1 {return}
	for i:=0;i<len(intervals^); {
		current:=intervals^[i]
		if remove.high<=current.low || remove.low>=current.high {i+=1;continue}
		if remove.low>current.low && remove.high<current.high {
			intervals^[i].high=remove.low;append(intervals,Clearance_Interval_3D{remove.high,current.high});i+=1
		} else if remove.low>current.low {intervals^[i].high=remove.low;i+=1
		} else if remove.high<current.high {intervals^[i].low=remove.high;i+=1
		} else {intervals^[i]=intervals^[len(intervals^)-1];pop(intervals)}
	}
}
clearance_edge_intervals_3d :: proc(q:^Clearance_Query_3D,a,b:[3]f32,triangle:i32=-1) -> [dynamic]Clearance_Interval_3D {
	intervals:=make([dynamic]Clearance_Interval_3D,0,4,q.allocator);append(&intervals,Clearance_Interval_3D{0,1})
	radius:=q.radius+0.002
	edges:=q.edges[:];if triangle>=0 {edges=clearance_triangle_edges_3d(q,triangle)}
	for edge in edges {
		if !clearance_same_layer_3d(q,a,b,edge) ||
			min(a.x,b.x)>max(edge.a.x,edge.b.x)+radius || max(a.x,b.x)<min(edge.a.x,edge.b.x)-radius ||
			min(a.z,b.z)>max(edge.a.z,edge.b.z)+radius || max(a.z,b.z)<min(edge.a.z,edge.b.z)-radius {continue}
		for endpoint in ([2][3]f32{edge.a,edge.b}) {
			interval,hit:=clearance_circle_interval_3d(a,b,endpoint,radius)
			if hit {clearance_subtract_interval_3d(&intervals,interval,q.allocator)}
		}
		d,p,travel:=edge.b-edge.a,a-edge.a,b-a
		length:=d.x*d.x+d.z*d.z
		interval:=Clearance_Interval_3D{0,1}
		if clearance_clip_linear_3d(&interval,p.x*d.x+p.z*d.z,travel.x*d.x+travel.z*d.z,0,length) &&
			clearance_clip_linear_3d(&interval,p.x*d.z-p.z*d.x,travel.x*d.z-travel.z*d.x,-radius*math.sqrt(length),radius*math.sqrt(length)) {
			clearance_subtract_interval_3d(&intervals,interval,q.allocator)
		}
		if len(intervals)==0 {break}
	}
	return intervals
}

clearance_leg_allowed_3d :: proc(q:^Clearance_Query_3D,a,b:[3]f32,triangle:i32=-1) -> bool {
	if triangle>=0 {return clearance_leg_edges_allowed_3d(q,a,b,clearance_triangle_edges_3d(q,triangle))}
	bounds:=Clearance_Bounds_3D{
		{min(a.x,b.x),min(a.y,b.y),min(a.z,b.z)},
		{max(a.x,b.x),max(a.y,b.y),max(a.z,b.z)}}
	for block,i in q.edge_blocks {
		if !clearance_bounds_overlap_3d(bounds,block,q.radius,q.vertical_range) {continue}
		first:=i*Clearance_Bounds_Block_Size_3D
		if !clearance_leg_edges_allowed_3d(q,a,b,q.edges[first:min(first+Clearance_Bounds_Block_Size_3D,len(q.edges))]) {return false}
	}
	return true
}

clearance_leg_edges_allowed_3d :: proc(q:^Clearance_Query_3D,a,b:[3]f32,edges:[]Clearance_Edge_3D) -> bool {
	for edge in edges {
		if !clearance_same_layer_3d(q,a,b,edge) ||
			min(a.x,b.x)>max(edge.a.x,edge.b.x)+q.radius || max(a.x,b.x)<min(edge.a.x,edge.b.x)-q.radius ||
			min(a.z,b.z)>max(edge.a.z,edge.b.z)+q.radius || max(a.z,b.z)<min(edge.a.z,edge.b.z)-q.radius {continue}
		// Segment/segment distance in XZ. Crossing boundaries is also rejected
		// by this test; caller restricts each leg to its one convex triangle.
		distance:=min(clearance_distance_xz_3d(a,clearance_closest_xz_3d(a,edge.a,edge.b)),
			clearance_distance_xz_3d(b,clearance_closest_xz_3d(b,edge.a,edge.b)),
			clearance_distance_xz_3d(edge.a,clearance_closest_xz_3d(edge.a,a,b)),
			clearance_distance_xz_3d(edge.b,clearance_closest_xz_3d(edge.b,a,b)))
		crosses:=funnel_area_xz_3d(a,b,edge.a)*funnel_area_xz_3d(a,b,edge.b)<0 &&
			funnel_area_xz_3d(edge.a,edge.b,a)*funnel_area_xz_3d(edge.a,edge.b,b)<0
		if crosses || distance<q.radius-0.0001 {return false}
	}
	return true
}

clearance_add_node_3d :: proc(q:^Clearance_Query_3D,p:[3]f32,first:i32=-1,second:i32=-1) -> i32 {
	index:=i32(len(q.nodes))
	node:=Clearance_Node_3D{point=p,score=3.402823e38,parent=-1,via_triangle=-1,members=make([dynamic]i32,0,2,q.allocator)}
	for triangle,i in ([2]i32{first,second}) {
		if triangle<0 || (i==1 && second==first) {continue}
		if q.triangle_nodes[triangle].allocator.procedure==nil {q.triangle_nodes[triangle]=make([dynamic]i32,0,8,q.allocator)}
		append(&node.members,triangle);append(&q.triangle_nodes[triangle],index)
	}
	append(&q.nodes,node)
	return index
}

clearance_corridor_leg_3d :: proc(q:^Clearance_Query_3D,path:^Path_3D,first,last:int,write:bool) -> bool {
	a,b:=path.points[first],path.points[last]
	if !clearance_leg_allowed_3d(q,a,b) {return false}
	progress:f32=0
	for k in first..<last {
		interval,ok:=surface_triangle_interval_3d(q.mesh,path.triangles[k],a,b)
		if !ok || interval.low>progress+1e-4 || interval.high<progress-1e-4 {return false}
		progress=max(progress,interval.high)
	}
	if progress<1-1e-4 {return false}
	if write {
		for k in first..<last-1 {
			interval,_:=surface_triangle_interval_3d(q.mesh,path.triangles[k],a,b)
			p:=a+(b-a)*math.clamp(interval.high,0,1)
			triangle:=q.mesh.triangles[path.triangles[k]];v:=q.mesh.vertices[triangle.vertices[0]]
			p.y=v.y-(triangle.normal.x*(p.x-v.x)+triangle.normal.z*(p.z-v.z))/triangle.normal.y
			path.points[k+1]=p
		}
	}
	return true
}

clearance_smooth_path_3d :: proc(q:^Clearance_Query_3D,path:^Path_3D) {
	for first:=0;first<len(path.points)-1; {
		last:=len(path.points)-1
		for last>first+1 && !clearance_corridor_leg_3d(q,path,first,last,false) {last-=1}
		if last>first+1 {clearance_corridor_leg_3d(q,path,first,last,true)}
		first=last
	}
}

// Apply extra footprint clearance to the shared surface trace. The ordinary
// query uses the same trace without constructing clearance geometry.
clearance_direct_path_3d :: proc(q:^Clearance_Query_3D,a,b:[3]f32,start,goal:i32,allocator:mem.Allocator) -> Path_3D {
	path:=surface_direct_path_3d(q.mesh,a,b,start,goal,q.options.max_slope,allocator)
	if path.status!=.Complete {return path}
	for i in 0..<len(path.points)-1 {
		if !clearance_leg_allowed_3d(q,path.points[i],path.points[i+1]) {
			delete(path.points,allocator);delete(path.triangles,allocator)
			return {status=.Unreachable}
		}
	}
	return path
}
clearance_add_portals_3d :: proc(q:^Clearance_Query_3D,index:i32) {
	triangle:=q.mesh.triangles[index]
	for neighbor,e in triangle.neighbors {
		if neighbor<0 || !q.component[neighbor] {continue}
		u,v:=triangle.vertices[e],triangle.vertices[(e+1)%3]
		key:=Edge_3D{min(u,v),max(u,v)}
		if q.portals[key] {continue};q.portals[key]=true
		a,b:=q.mesh.vertices[u],q.mesh.vertices[v]
		intervals:=clearance_edge_intervals_3d(q,a,b,index)
		for interval in intervals {
			if interval.high-interval.low<1e-5 {continue}
			for t in ([3]f32{interval.low,(interval.low+interval.high)*0.5,interval.high}) {
				p:=a+(b-a)*t
				if clearance_point_allowed_3d(q,p,index) {clearance_add_node_3d(q,p,index,neighbor)}
			}
		}
	}
}

// Mitred inset corner points allow a safe turn around an inflated obstacle
// even when the straight chord between two portal intervals clips its corner.
clearance_add_corners_3d :: proc(q:^Clearance_Query_3D) {
	first:=make([]i32,len(q.mesh.vertices),q.allocator);for &i in first {i=-1}
	for edge,i in q.edges {
		for vertex in edge.vertices {
			other:=first[vertex]
			if other<0 {first[vertex]=i32(i);continue}
			a,b:=q.edges[other].normal,edge.normal
			if dot_3d(a,b)>0.99999 {continue}
			sum:=a+b;length:=length_3d(sum)
			if length<1e-5 {continue};direction:=sum/length;divisor:=dot_3d(direction,a)
			if divisor<0.1 {continue}
			p:=q.mesh.vertices[vertex]+direction*((q.radius+0.004)/divisor)
			projected,triangle,ok:=clearance_project_surface_3d(q,p,q.radius*4+0.1)
			if !ok || !clearance_point_allowed_3d(q,projected,triangle) {continue}
			clearance_add_node_3d(q,projected,triangle)
		}
	}
}

find_clearance_path_3d :: proc(mesh:^Mesh_3D,start,goal:[3]f32,options:Path_Options_3D,allocator:mem.Allocator,preparation:^Clearance_Preparation_3D=nil) -> Path_3D {
	s,si,start_ok:=project_point_3d(mesh,start,options.max_projection,options.max_slope)
	if !start_ok {return {status=.Start_Off_Mesh}}
	g,gi,goal_ok:=project_point_3d(mesh,goal,options.max_projection,options.max_slope)
	if !goal_ok {return {status=.Goal_Off_Mesh}}
	prepared:=clearance_preparation_matches_3d(preparation,mesh,options,si)
	q:Clearance_Query_3D
	if prepared {
		// Only immutable geometry is used until the fallback graph is needed.
		q=preparation.query;q.options=options;q.allocator=context.temp_allocator
	} else {q=clearance_query_3d(mesh,options,si)}
	if !q.component[gi] {return {status=.Unreachable}}
	s,si,start_ok=clearance_project_point_3d(&q,start,s,si)
	if !start_ok {return {status=.Start_Off_Mesh}}
	g,gi,goal_ok=clearance_project_point_3d(&q,goal,g,gi)
	if !goal_ok {return {status=.Goal_Off_Mesh}}
	direct:=clearance_direct_path_3d(&q,s,g,si,gi,allocator)
	if direct.status==.Complete {return direct}
	// Most repaths across open rooms need no extra graph at all. Keep the
	// ordinary funnel route when every complete leg already has clearance.
	base_options:=options;base_options.radius=mesh.agent_radius
	ordinary:=find_path_3d(mesh,s,g,base_options,allocator)
	ordinary_safe:=ordinary.status==.Complete
	if ordinary_safe {for i in 0..<len(ordinary.points)-1 {
		if !clearance_leg_allowed_3d(&q,ordinary.points[i],ordinary.points[i+1]) {ordinary_safe=false;break}
	}}
	if ordinary_safe {return ordinary}
	delete(ordinary.points,allocator);delete(ordinary.triangles,allocator)
	if prepared {q=clearance_prepared_query_3d(preparation,options,s,g,si,gi)} else {
		clearance_add_node_3d(&q,s,si);clearance_add_node_3d(&q,g,gi)
		clearance_add_corners_3d(&q)
	}
	heap:=make([dynamic]Heap_Node_3D,q.allocator)
	q.nodes[0].score=0;heap_push_3d(&heap,{0,distance_3d(s,g)})
	for len(heap)>0 {
		current:=heap_pop_3d(&heap).triangle
		if q.nodes[current].closed {continue};q.nodes[current].closed=true
		if current==1 {break}
		for triangle in q.nodes[current].members {
			clearance_add_portals_3d(&q,triangle)
			for neighbor in q.triangle_nodes[triangle] {
				if q.nodes[neighbor].closed {continue}
				score:=q.nodes[current].score+distance_3d(q.nodes[current].point,q.nodes[neighbor].point)
				if score<q.nodes[neighbor].score && clearance_leg_allowed_3d(&q,q.nodes[current].point,q.nodes[neighbor].point,triangle) {
					q.nodes[neighbor].score=score;q.nodes[neighbor].parent=current;q.nodes[neighbor].via_triangle=triangle
					heap_push_3d(&heap,{neighbor,score+distance_3d(q.nodes[neighbor].point,g)})
				}
			}
		}
	}
	if !q.nodes[1].closed {return {status=.Unreachable}}
	reversed:=make([dynamic]i32,q.allocator)
	for cursor:=i32(1);cursor>=0;cursor=q.nodes[cursor].parent {append(&reversed,cursor)}
	path:=Path_3D{status=.Complete,points=make([][3]f32,len(reversed),allocator),triangles=make([]i32,len(reversed)-1,allocator)}
	for index,i in reversed {
		destination:=len(reversed)-1-i;path.points[destination]=q.nodes[index].point
		if destination>0 {path.triangles[destination-1]=q.nodes[index].via_triangle}
	}
	clearance_smooth_path_3d(&q,&path)
	return path
}
