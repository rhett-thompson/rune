package navigation

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"

direct_test_path_length_3d :: proc(path:^Path_3D) -> f32 {
	length:f32
	for i in 1..<len(path.points) {length+=distance_3d(path.points[i-1],path.points[i])}
	return length
}

direct_test_path_surface_3d :: proc(t:^testing.T,mesh:^Mesh_3D,path:^Path_3D,start,goal:[3]f32,options:Path_Options_3D) {
	if !testing.expect(t,path.status==.Complete,"path reaches the projected goal") {return}
	if !testing.expect(t,len(path.points)==len(path.triangles)+1 && len(path.triangles)>0,"each segment identifies its surface triangle") {return}
	testing.expect(t,distance_3d(path.points[0],start)<0.001 && distance_3d(path.points[len(path.points)-1],goal)<0.001,"projected endpoints are preserved")
	for triangle,i in path.triangles {
		if !testing.expect(t,triangle_allowed_3d(mesh,triangle,options.max_slope),"path only visits unblocked triangles within the slope limit") {continue}
		if i>0 {
			connected:=false
			for neighbor in mesh.triangles[path.triangles[i-1]].neighbors {if neighbor==triangle {connected=true}}
			testing.expect(t,connected,"consecutive path triangles share an actual mesh edge")
		}
		for sample in 0..=4 {
			point:=path.points[i]+(path.points[i+1]-path.points[i])*(f32(sample)/4)
			testing.expect(t,distance_3d(closest_triangle_3d(mesh,triangle,point),point)<0.001,"each path segment remains on its declared triangle")
		}
	}
}

direct_test_owned_path_3d :: proc(t:^testing.T,mesh:^Mesh_3D,start,goal:[3]f32,options:Path_Options_3D) {
	// An explicit result allocator owns both arrays, independently of search
	// scratch storage, and the public destructor releases them through it.
	tracking:mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking,context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	output_allocator:=mem.tracking_allocator(&tracking)
	path:=find_path_3d(mesh,start,goal,options,output_allocator)
	_,owns_points:=tracking.allocation_map[rawptr(raw_data(path.points))]
	_,owns_triangles:=tracking.allocation_map[rawptr(raw_data(path.triangles))]
	testing.expect(t,owns_points && owns_triangles,"complete paths copy both arrays into the supplied allocator")
	context.allocator=output_allocator
	destroy_path_3d(&path)
	testing.expect(t,len(tracking.allocation_map)==0 && path.status==.Invalid && len(path.points)==0 && len(path.triangles)==0,"destruction releases result storage and clears the path")
}

@(test)
ordinary_path_avoids_simplified_hole_centroid_detour :: proc(t:^testing.T) {
	geometry:Bake_Geometry_3D
	defer destroy_bake_geometry_3d(&geometry)
	vertices:=[4][3]f32{{-10,0,-10},{10,0,-10},{10,0,10},{-10,0,10}}
	faces:=[2][3]i32{{0,2,1},{0,3,2}}
	if !testing.expect(t,append_bake_triangles_3d(&geometry,vertices[:],faces[:])) {return}
	if !testing.expect(t,append_bake_box_3d(&geometry,{2,3,2},{0,1.5,0},obstacle=true)) {return}
	settings:=Default_Bake_Settings_3D
	simplified,_,error:=bake_mesh_3d(geometry,settings)
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&simplified)
	settings.simplify=false
	raw,_,raw_error:=bake_mesh_3d(geometry,settings)
	if !testing.expect(t,raw_error=="",raw_error) {return};defer destroy_mesh_3d(&raw)
	testing.expect(t,len(simplified.triangles)*4<len(raw.triangles),"straight paths retain the simplified mesh's triangle reduction")
	settings.simplify=true;settings.cell_size=0.25
	finer,_,finer_error:=bake_mesh_3d(geometry,settings)
	if !testing.expect(t,finer_error=="",finer_error) {return};defer destroy_mesh_3d(&finer)
	start:=[3]f32{-2.87,0,2.17};goal:=[3]f32{5.13,0,2.17}
	options:=Default_Path_Options_3D;options.max_projection=0.001
	for mesh in ([3]^Mesh_3D{&simplified,&raw,&finer}) {for radius in ([2]f32{0.3,0.4}) {for reverse in 0..<2 {
		options.radius=radius
		a,b:=start,goal;if reverse==1 {a,b=b,a}
		path:=find_path_3d(mesh,a,b,options)
		direct_test_path_surface_3d(t,mesh,&path,a,b,options)
		testing.expect(t,abs(direct_test_path_length_3d(&path)-8)<0.001,fmt.tprintf("clear eight-unit route must not follow the centroid-favored detour; got %.6f",direct_test_path_length_3d(&path)))
		destroy_path_3d(&path)
	}}}
	direct_test_owned_path_3d(t,&simplified,start,goal,options)
}

@(test)
ordinary_surface_trace_respects_obstacles_and_real_shared_edges :: proc(t:^testing.T) {
	keep:=[9]bool{true,true,true,true,true,true,true,true,true}
	mesh,error:=clearance_test_grid_3d(3,3,keep[:])
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	options:=Default_Path_Options_3D;options.max_projection=0.001
	start:=[3]f32{0.2,0,1.5};goal:=[3]f32{2.8,0,1.5}
	for &triangle in mesh.triangles {
		if triangle.center.x>1 && triangle.center.x<2 && triangle.center.z>1 && triangle.center.z<2 {triangle.blocked=true}
	}
	blocked:=find_path_3d(&mesh,start,goal,options)
	direct_test_path_surface_3d(t,&mesh,&blocked,start,goal,options)
	testing.expect(t,direct_test_path_length_3d(&blocked)>distance_3d(start,goal)+0.1,"a blocked direct trace falls back to a safe detour")
	destroy_path_3d(&blocked)
	// A missing center cell must act as a hole even without blocked flags.
	keep[4]=false
	hole,hole_error:=clearance_test_grid_3d(3,3,keep[:])
	if !testing.expect(t,hole_error=="",hole_error) {return};defer destroy_mesh_3d(&hole)
	missing:=find_path_3d(&hole,start,goal,options)
	direct_test_path_surface_3d(t,&hole,&missing,start,goal,options)
	testing.expect(t,direct_test_path_length_3d(&missing)>distance_3d(start,goal)+0.1,"a surface hole cannot become a straight shortcut")
	destroy_path_3d(&missing)
	// These quads touch spatially, but distinct vertex indices mean their
	// common-looking edge is not traversable mesh topology.
	split,split_error:=build_mesh_3d({version=1,agent_radius=0.4,agent_height=2,
		vertices=[][3]f32{{0,0,0},{1,0,0},{1,0,1},{0,0,1},{1,0,0},{2,0,0},{2,0,1},{1,0,1}},
		triangles=[][3]i32{{0,1,2},{0,2,3},{4,5,6},{4,6,7}}})
	if !testing.expect(t,split_error=="",split_error) {return};defer destroy_mesh_3d(&split)
	disconnected:=find_path_3d(&split,{0.2,0,0.4},{1.8,0,0.4},options)
	testing.expect(t,disconnected.status==.Unreachable,"surface tracing requires shared vertex indices at every crossing")
	destroy_path_3d(&disconnected)
	// XZ overlap cannot connect two elevations with no authored edge.
	floors,floor_error:=build_mesh_3d({version=1,agent_radius=0.4,agent_height=2,
		vertices=[][3]f32{{0,0,0},{4,0,0},{4,0,4},{0,0,4},{0,3,0},{4,3,0},{4,3,4},{0,3,4}},
		triangles=[][3]i32{{0,1,2},{0,2,3},{4,5,6},{4,6,7}}})
	if !testing.expect(t,floor_error=="",floor_error) {return};defer destroy_mesh_3d(&floors)
	across:=find_path_3d(&floors,{0.5,0,1},{3.5,3,1},options)
	testing.expect(t,across.status==.Unreachable,"overlapping disconnected floors stay unreachable")
	destroy_path_3d(&across)
	upper_start:=[3]f32{0.5,3,1};upper_goal:=[3]f32{3.5,3,1}
	upper:=find_path_3d(&floors,upper_start,upper_goal,options)
	direct_test_path_surface_3d(t,&floors,&upper,upper_start,upper_goal,options)
	for point in upper.points {testing.expect(t,abs(point.y-3)<0.001,"a direct path remains on the selected floor")}
	destroy_path_3d(&upper)
}

@(test)
ordinary_surface_trace_preserves_ramp_height_and_slope_limit :: proc(t:^testing.T) {
	keep:=[12]bool{true,true,true,true,true,true,true,true,true,true,true,true}
	heights:=[21]f32{}
	for z in 0..=2 {for x in 0..=6 {heights[z*7+x]=math.clamp(f32(x)-2,0,2)*0.5}}
	mesh,error:=clearance_test_grid_3d(6,2,keep[:],heights[:])
	if !testing.expect(t,error=="",error) {return};defer destroy_mesh_3d(&mesh)
	options:=Default_Path_Options_3D;options.max_projection=0.001
	start:=[3]f32{0.5,0,0.8};goal:=[3]f32{5.5,1,0.8}
	for reverse in 0..<2 {
		a,b:=start,goal;if reverse==1 {a,b=b,a}
		path:=find_path_3d(&mesh,a,b,options)
		direct_test_path_surface_3d(t,&mesh,&path,a,b,options)
		testing.expect(t,abs(direct_test_path_length_3d(&path)-(3+math.sqrt(f32(5))))<0.001,"direct XZ traversal follows both flat sections and the ramp instead of a 3D chord")
		for point in path.points {
			testing.expect(t,abs(point.z-0.8)<0.001 && abs(point.y-math.clamp(point.x-2,0,2)*0.5)<0.001,"every crossing preserves the real surface height")
		}
		destroy_path_3d(&path)
	}
	options.max_slope=15
	steep:=find_path_3d(&mesh,start,goal,options)
	testing.expect(t,steep.status==.Unreachable,"allowed flat endpoints cannot cross an intervening ramp above the query's slope limit")
	destroy_path_3d(&steep)
}
