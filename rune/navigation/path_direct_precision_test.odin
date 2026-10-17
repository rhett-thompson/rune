package navigation

import "core:testing"

@(test)
ordinary_surface_trace_does_not_scale_tolerance_across_a_hole :: proc(t:^testing.T) {
	xs:=[4]f32{-100000,-1,1,100000}
	zs:=[4]f32{-3,-1,1,3}
	vertices:=make([][3]f32,16,context.temp_allocator)
	for z in 0..<4 {for x in 0..<4 {vertices[z*4+x]={xs[x],0,zs[z]}}}
	triangles:=make([dynamic][3]i32,context.temp_allocator)
	for z in 0..<3 {for x in 0..<3 {
		if x==1 && z==1 {continue}
		a,b:=i32(z*4+x),i32((z+1)*4+x)
		append(&triangles,[3]i32{a,b,a+1},[3]i32{a+1,b,b+1})
	}}
	mesh,error:=build_mesh_3d({version=1,agent_radius=0.4,agent_height=2,vertices=vertices,triangles=triangles[:]})
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	options:=Default_Path_Options_3D;options.max_projection=0.001
	start:=[3]f32{-90000,0,0.8};goal:=[3]f32{90000,0,1.2}
	s,si,start_ok:=project_point_3d(&mesh,start,options.max_projection,options.max_slope)
	g,gi,goal_ok:=project_point_3d(&mesh,goal,options.max_projection,options.max_slope)
	if !testing.expect(t,start_ok && goal_ok,"both endpoints lie on the same connected room") {return}
	// The segment clips the upper-left hole corner. A tolerance measured in
	// normalized segment parameters must not bridge a whole unit of missing
	// surface when the endpoints are far apart.
	direct:=surface_direct_path_3d(&mesh,s,g,si,gi,options.max_slope,context.allocator)
	defer destroy_path_3d(&direct)
	testing.expect(t,direct.status==.Unreachable,"a long trace still requires actual shared-edge crossings at a hole corner")
}
