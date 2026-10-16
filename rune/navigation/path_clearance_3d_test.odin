package navigation

import "core:math"
import "core:testing"

clearance_test_grid_3d :: proc(width,depth:int,keep:[]bool,height:[]f32=nil) -> (Mesh_3D,string) {
	vertices:=make([][3]f32,(width+1)*(depth+1),context.temp_allocator)
	for z in 0..=depth {for x in 0..=width {
		y:f32=0;if len(height)>0 {y=height[z*(width+1)+x]}
		vertices[z*(width+1)+x]={f32(x),y,f32(z)}
	}}
	triangles:=make([dynamic][3]i32,context.temp_allocator)
	for z in 0..<depth {for x in 0..<width {
		if !keep[z*width+x] {continue}
		a,b:=i32(z*(width+1)+x),i32((z+1)*(width+1)+x)
		append(&triangles,[3]i32{a,b,a+1},[3]i32{a+1,b,b+1})
	}}
	return build_mesh_3d({version=1,agent_radius=0.34,agent_height=2,vertices=vertices,triangles=triangles[:]})
}
clearance_test_options_3d :: proc(radius:f32) -> Path_Options_3D {
	return {radius=radius,height=1.5,max_slope=30,max_projection=2}
}
clearance_test_path_safe_3d :: proc(t:^testing.T,mesh:^Mesh_3D,path:^Path_3D,options:Path_Options_3D) {
	if !testing.expect(t,path.status==.Complete) {return}
	q:=clearance_query_3d(mesh,options,path.triangles[0])
	for triangle,i in path.triangles {
		testing.expect(t,clearance_leg_allowed_3d(&q,path.points[i],path.points[i+1]),"whole agent radius stays clear of boundaries")
		testing.expect(t,distance_3d(closest_triangle_3d(mesh,triangle,path.points[i]),path.points[i])<0.001)
		testing.expect(t,distance_3d(closest_triangle_3d(mesh,triangle,path.points[i+1]),path.points[i+1])<0.001)
	}
}

@(test)
shared_mesh_supports_different_agent_radii :: proc(t:^testing.T) {
	keep:=make([]bool,20*16,context.temp_allocator);for &cell in keep {cell=true}
	mesh,error:=clearance_test_grid_3d(20,16,keep)
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	vertices,triangles:=raw_data(mesh.vertices),raw_data(mesh.triangles)
	options:=clearance_test_options_3d(1.98)
	path:=find_path_3d(&mesh,{3,0,3},{17,0,13},options);defer destroy_path_3d(&path)
	clearance_test_path_safe_3d(t,&mesh,&path,options)
	if path.status==.Complete {for point in path.points {
		testing.expect(t,abs(area_xz(path.points[0],path.points[len(path.points)-1],point))<0.002,"open floor path stays straight across interior triangulation")
	}}
	testing.expect(t,raw_data(mesh.vertices)==vertices && raw_data(mesh.triangles)==triangles,"query retains one shared mesh")
	for triangle in mesh.triangles {testing.expect(t,!triangle.blocked,"query never carves shared triangles")}
}

@(test)
shared_mesh_clearance_chooses_wider_alternate_route :: proc(t:^testing.T) {
	// Rooms connect through a two-unit shortcut and a six-unit lower passage.
	keep:=make([]bool,32*24,context.temp_allocator)
	for z in 0..<24 {for x in 0..<32 {
		keep[z*32+x]=x<12 || x>=20 || z<6 || (z>=13 && z<15)
	}}
	mesh,error:=clearance_test_grid_3d(32,24,keep)
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	small:=find_path_3d(&mesh,{6,0,14},{26,0,14},clearance_test_options_3d(0.34));defer destroy_path_3d(&small)
	testing.expect(t,small.status==.Complete)
	options:=clearance_test_options_3d(1.98)
	large:=find_path_3d(&mesh,{6,0,14},{26,0,14},options);defer destroy_path_3d(&large)
	clearance_test_path_safe_3d(t,&mesh,&large,options)
	used_wide_route:=false
	for point in large.points {if point.x>=12 && point.x<=20 && point.z<6 {used_wide_route=true}}
	testing.expect(t,used_wide_route,"large agent takes the wide connection while small agent can take the shortcut")
	for z in 0..<6 {for x in 12..<20 {for &triangle in mesh.triangles {
		if triangle.center.x>f32(x) && triangle.center.x<f32(x+1) && triangle.center.z>f32(z) && triangle.center.z<f32(z+1) {triangle.blocked=true}
	}}}
	blocked:=find_path_3d(&mesh,{6,0,14},{26,0,14},options);defer destroy_path_3d(&blocked)
	testing.expect(t,blocked.status==.Unreachable,"large agent cannot squeeze through the remaining narrow connection")
}

@(test)
shared_mesh_clearance_insets_obstacle_corners :: proc(t:^testing.T) {
	keep:=make([]bool,24*20,context.temp_allocator)
	for z in 0..<20 {for x in 0..<24 {keep[z*24+x]=!(x>=10 && x<14 && z>=5 && z<15)}}
	mesh,error:=clearance_test_grid_3d(24,20,keep)
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	options:=clearance_test_options_3d(1.98)
	path:=find_path_3d(&mesh,{5,0,10},{19,0,10},options);defer destroy_path_3d(&path)
	clearance_test_path_safe_3d(t,&mesh,&path,options)
	for i in 0..<len(path.points)-1 {for sample in 0..=8 {
		p:=path.points[i]+(path.points[i+1]-path.points[i])*(f32(sample)/8)
		closest:=[3]f32{math.clamp(p.x,10,14),0,math.clamp(p.z,5,15)}
		testing.expect(t,clearance_distance_xz_3d(p,closest)>=1.98-0.34-0.001,"corner is inset for the agent footprint")
	}}
}

@(test)
shared_mesh_clearance_preserves_ramps_and_disconnected_floors :: proc(t:^testing.T) {
	keep:=make([]bool,20*12,context.temp_allocator);for &cell in keep {cell=true}
	heights:=make([]f32,21*13,context.temp_allocator)
	for z in 0..=12 {for x in 0..=20 {heights[z*21+x]=math.clamp(f32(x)-6,0,8)*0.5}}
	mesh,error:=clearance_test_grid_3d(20,12,keep,heights)
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	options:=clearance_test_options_3d(1.98)
	path:=find_path_3d(&mesh,{3,0,6},{17,4,6},options);defer destroy_path_3d(&path)
	clearance_test_path_safe_3d(t,&mesh,&path,options)
	// Two overlapping floors with distinct vertex indices remain disconnected.
	vertices:=[][3]f32{{0,0,0},{10,0,0},{10,0,10},{0,0,10},{0,4,0},{10,4,0},{10,4,10},{0,4,10}}
	floors,floor_error:=build_mesh_3d({version=1,agent_radius=0.34,agent_height=2,vertices=vertices,triangles=[][3]i32{{0,1,2},{0,2,3},{4,5,6},{4,6,7}}})
	if !testing.expect(t,floor_error=="",floor_error) {return};defer destroy_mesh_3d(&floors)
	across:=find_path_3d(&floors,{3,0,3},{7,4,7},options);defer destroy_path_3d(&across)
	testing.expect(t,across.status==.Unreachable)
	upper:=find_path_3d(&floors,{3,4,3},{7,4,7},options);defer destroy_path_3d(&upper)
	clearance_test_path_safe_3d(t,&floors,&upper,options)
}

@(test)
shared_mesh_agent_projection_respects_radius_and_headroom :: proc(t:^testing.T) {
	keep:=make([]bool,12*12,context.temp_allocator);for &cell in keep {cell=true}
	mesh,error:=clearance_test_grid_3d(12,12,keep)
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	options:=clearance_test_options_3d(1.98)
	p,_,ok:=project_agent_point_3d(&mesh,{0.2,0,6},options)
	testing.expect(t,ok && p.x>=1.98-0.34-0.001,"agent projection insets its center from the boundary")
	options.height=2.5
	path:=find_path_3d(&mesh,{3,0,3},{9,0,9},options);defer destroy_path_3d(&path)
	testing.expect(t,path.status==.Insufficient_Clearance,"unsupported headroom stays a separate failure")
}
