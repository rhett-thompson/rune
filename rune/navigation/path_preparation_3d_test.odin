package navigation

import "core:testing"

@(test)
clearance_preparation_preserves_queries_and_immutable_templates :: proc(t:^testing.T) {
	keep:=make([]bool,24*20,context.temp_allocator)
	for z in 0..<20 {for x in 0..<24 {keep[z*24+x]=!(x>=10 && x<14 && z>=5 && z<15)}}
	mesh,error:=clearance_test_grid_3d(24,20,keep)
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	options:=clearance_test_options_3d(1.98)
	_,start_triangle,found:=project_point_3d(&mesh,{5,0,10},options.max_projection,options.max_slope)
	if !testing.expect(t,found) {return}
	borrowed:=mesh
	preparation:=create_clearance_preparation_3d(borrowed,options,start_triangle)
	if !testing.expect(t,preparation!=nil) {return};defer destroy_clearance_preparation_3d(preparation)
	borrowed={}
	testing.expect(t,preparation.query.mesh==&preparation.mesh && raw_data(preparation.mesh.triangles)==raw_data(mesh.triangles),"preparation borrows array storage through its own stable mesh value")
	corner_count:=len(preparation.query.nodes)
	testing.expect(t,corner_count>2 && len(preparation.query.portals)==0,"only corner templates and reserved endpoints are retained")
	starts:=[][3]f32{{5,0,10},{5,0,3},{19,0,10},{5,0,17}}
	goals:=[][3]f32{{19,0,10},{19,0,3},{5,0,10},{19,0,17}}
	for start,i in starts {
		actual:=find_path_3d(&mesh,start,goals[i],options,context.allocator,preparation)
		expected:=find_path_3d(&mesh,start,goals[i],options)
		testing.expect(t,actual.status==expected.status && len(actual.points)==len(expected.points) && len(actual.triangles)==len(expected.triangles),"cached and uncached searches return the same complete corridor")
		if len(actual.points)==len(expected.points) {for point,j in actual.points {testing.expect(t,point==expected.points[j],"preparation preserves exact point ordering")}}
		if len(actual.triangles)==len(expected.triangles) {for triangle,j in actual.triangles {testing.expect(t,triangle==expected.triangles[j],"preparation preserves exact triangle ordering")}}
		clearance_test_path_safe_3d(t,&mesh,&actual,options)
		destroy_path_3d(&actual);destroy_path_3d(&expected)
	}
	testing.expect(t,len(preparation.query.nodes)==corner_count && len(preparation.query.portals)==0,"queries retain independent graph growth")
	for node in preparation.query.nodes {testing.expect(t,!node.closed && node.parent==-1 && node.via_triangle==-1 && node.score==3.402823e38,"queries never mutate template search state")}
	for connected,i in preparation.query.component {
		if connected {testing.expect(t,preparation.query.triangle_edges[i].allocator.procedure!=nil,"all retained boundary candidate lists are prepared read-only")}
	}
	changed:=options;changed.radius+=0.2
	testing.expect(t,!clearance_preparation_matches_3d(preparation,&mesh,changed,start_triangle),"a different footprint does not reuse the prepared geometry")
	changed=options;changed.max_slope+=1
	testing.expect(t,!clearance_preparation_matches_3d(preparation,&mesh,changed,start_triangle),"a different slope limit does not reuse the connected component")
}
