package main

import "core:fmt"
import "rune:navigation"

smoothing_mesh :: proc(vertices: [][3]f32, triangles: [][3]i32) -> navigation.Mesh_3D {
	mesh,error := navigation.build_mesh_3d({version=1,agent_radius=0.5,agent_height=2,vertices=vertices,triangles=triangles})
	assert(error=="",error)
	return mesh
}

smoothing_corridor :: proc(mesh: ^navigation.Mesh_3D, path: ^navigation.Path_3D) {
	assert(path.status==.Complete)
	assert(len(path.points)==len(path.triangles)+1,"smoothed paths retain each surface crossing")
	for triangle,i in path.triangles {
		assert(!mesh.triangles[triangle].blocked)
		for sample in 0..=32 {
			point := path.points[i]+(path.points[i+1]-path.points[i])*(f32(sample)/32)
			assert(navigation.finite_point_3d(point))
			nearest := navigation.closest_triangle_3d(mesh,triangle,point)
			assert(navigation.distance_3d(nearest,point)<0.001,"smoothed segment stays on its corridor triangle")
		}
	}
}

smoothing_length :: proc(path: ^navigation.Path_3D) -> f32 {
	length: f32
	for i in 0..<len(path.points)-1 {length+=navigation.distance_3d(path.points[i],path.points[i+1])}
	return length
}

smoothing_direct :: proc(mesh: ^navigation.Mesh_3D, start,goal: [3]f32) {
	path := navigation.find_path_3d(mesh,start,goal)
	defer navigation.destroy_path_3d(&path)
	smoothing_corridor(mesh,&path)
	assert(navigation.distance_3d(path.points[0],start)<0.001)
	assert(navigation.distance_3d(path.points[len(path.points)-1],goal)<0.001)
	assert(abs(smoothing_length(&path)-navigation.distance_3d(start,goal))<0.001,"open floor route goes directly to the target")
}

validate_path_smoothing :: proc() {
	// A simplified floor can contain only two large triangles. Their shared
	// midpoint is far from the straight route for these asymmetric endpoints.
	floor_vertices := [][3]f32{{0,0,0},{10,0,0},{10,0,10},{0,0,10}}
	for reversed in ([2]bool{false,true}) {
		floor_triangles := [][3]i32{{0,1,2},{0,2,3}}
		if reversed {floor_triangles=[][3]i32{{2,1,0},{3,2,0}}}
		mesh := smoothing_mesh(floor_vertices,floor_triangles)
		smoothing_direct(&mesh,{1,0,8},{9,0,3})
		smoothing_direct(&mesh,{9,0,3},{1,0,8})
		smoothing_direct(&mesh,{2,0,2},{2,0,2})
		navigation.destroy_mesh_3d(&mesh)
	}
	// Consecutive rectangular sections include parallel portals and several
	// diagonal portals. Boundary paths cross shared vertices and can leave
	// consecutive zero-length segments in the triangle-aligned point array.
	strip := smoothing_mesh(
		[][3]f32{{0,0,0},{4,0,0},{8,0,0},{12,0,0},{0,0,3},{4,0,3},{8,0,3},{12,0,3}},
		[][3]i32{{0,1,5},{0,5,4},{1,2,6},{1,6,5},{2,3,7},{2,7,6}})
	defer navigation.destroy_mesh_3d(&strip)
	smoothing_direct(&strip,{0.5,0,0.4},{11.5,0,2.6})
	smoothing_direct(&strip,{11.5,0,2.6},{0.5,0,0.4})
	smoothing_direct(&strip,{0.5,0,0},{11.5,0,0})
	smoothing_direct(&strip,{11.5,0,0},{0.5,0,0})
	smoothing_direct(&strip,{4,0,0},{4,0,0})
	smoothing_direct(&strip,{4,0,0},{11.5,0,0})
	// A start inside a shared edge can belong to the face behind its travel
	// direction. The first crossing must stay at the start, even when further
	// portals share an endpoint with that edge. Vary face order and winding so
	// both travel directions exercise this zero-length initial crossing.
	for reversed_winding in ([]bool{false,true}) {
		for reversed_order in ([]bool{false,true}) {
			indices:=make([][3]i32,6,context.temp_allocator)
			for triangle,i in ([][3]i32{{0,1,5},{0,5,4},{1,2,6},{1,6,5},{2,3,7},{2,7,6}}) {
				oriented:=triangle
				if reversed_winding {oriented[0],oriented[2]=oriented[2],oriented[0]}
				index:=len(indices)-1-i if reversed_order else i
				indices[index]=oriented
			}
			boundary:=smoothing_mesh(strip.vertices,indices)
			smoothing_direct(&boundary,{4,0,1.1},{11.5,0,1.1})
			smoothing_direct(&boundary,{8,0,1.1},{0.5,0,1.1})
			smoothing_direct(&boundary,{2,0,1.5},{11.5,0,2.7})
			smoothing_direct(&boundary,{10,0,1.5},{0.5,0,0.4})
			navigation.destroy_mesh_3d(&boundary)
		}
	}
	// The missing upper-left floor is an obstacle. A legal shortest route
	// touches the inside corner rather than cutting across the missing area.
	turn := smoothing_mesh(
		[][3]f32{{0,0,0},{4,0,0},{6,0,0},{0,0,2},{4,0,2},{6,0,2},{4,0,6},{6,0,6}},
		[][3]i32{{0,1,4},{0,4,3},{1,2,5},{1,5,4},{4,5,7},{4,7,6}})
	defer navigation.destroy_mesh_3d(&turn)
	for reversed in ([2]bool{false,true}) {
		start,goal := [3]f32{1,0,1},[3]f32{5,0,5}
		if reversed {start,goal=goal,start}
		path := navigation.find_path_3d(&turn,start,goal)
		smoothing_corridor(&turn,&path)
		corner := [3]f32{4,0,2}
		expected := navigation.distance_3d(start,corner)+navigation.distance_3d(corner,goal)
		assert(abs(smoothing_length(&path)-expected)<0.001,"obstacle route turns at the inside corner")
		navigation.destroy_path_3d(&path)
	}
	turn.triangles[3].blocked=true
	blocked := navigation.find_path_3d(&turn,{1,0,1},{5,0,5})
	assert(blocked.status==.Unreachable && len(blocked.points)==0,"smoothing does not bypass a blocked corridor")
	navigation.destroy_path_3d(&blocked)
	// Two corners require the funnel to restart without losing a portal.
	u_turn := smoothing_mesh(
		[][3]f32{{0,0,0},{2,0,0},{6,0,0},{0,0,2},{2,0,2},{6,0,2},{0,0,6},{2,0,6},{6,0,6},{0,0,8},{2,0,8},{6,0,8}},
		[][3]i32{{0,1,4},{0,4,3},{1,2,5},{1,5,4},{3,4,7},{3,7,6},{6,7,10},{6,10,9},{7,8,11},{7,11,10}})
	defer navigation.destroy_mesh_3d(&u_turn)
	for reversed in ([2]bool{false,true}) {
		start,goal := [3]f32{5,0,1},[3]f32{5,0,7}
		if reversed {start,goal=goal,start}
		path := navigation.find_path_3d(&u_turn,start,goal)
		smoothing_corridor(&u_turn,&path)
		expected := 2*navigation.distance_3d([3]f32{5,0,1},[3]f32{2,0,2})+4
		assert(abs(smoothing_length(&path)-expected)<0.001,"multiple turns follow the inside corners")
		navigation.destroy_path_3d(&path)
	}
	// Flattening the route for the funnel must preserve the surface height
	// when the path enters and leaves a ramp between level floors.
	ramp := smoothing_mesh(
		[][3]f32{{0,0,0},{4,0,0},{8,2,0},{12,2,0},{0,0,4},{4,0,4},{8,2,4},{12,2,4}},
		[][3]i32{{0,1,5},{0,5,4},{1,2,6},{1,6,5},{2,3,7},{2,7,6}})
	defer navigation.destroy_mesh_3d(&ramp)
	for reversed in ([2]bool{false,true}) {
		start,goal := [3]f32{1,0,0.7},[3]f32{11,2,3.1}
		if reversed {start,goal=goal,start}
		path := navigation.find_path_3d(&ramp,start,goal)
		smoothing_corridor(&ramp,&path)
		for point in path.points {
			assert(abs(navigation.area_xz(start,goal,point))<0.001,"ramp path has no sideways portal detours")
			height := max(f32(0),min(f32(2),(point.x-4)/2))
			assert(abs(point.y-height)<0.001,"ramp crossings retain the surface height")
		}
		navigation.destroy_path_3d(&path)
	}
	// XZ overlap never lets smoothing connect distinct floors or interpolate
	// the upper-floor route down toward the lower floor.
	stacked := smoothing_mesh(
		[][3]f32{{0,0,0},{10,0,0},{10,0,10},{0,0,10},{0,3,0},{10,3,0},{10,3,10},{0,3,10}},
		[][3]i32{{0,1,2},{0,2,3},{4,5,6},{4,6,7}})
	defer navigation.destroy_mesh_3d(&stacked)
	smoothing_direct(&stacked,{1,3,8},{9,3,3})
	between_floors := navigation.find_path_3d(&stacked,{1,0,8},{9,3,3})
	assert(between_floors.status==.Unreachable && len(between_floors.points)==0)
	navigation.destroy_path_3d(&between_floors)
	fmt.println("PASS straight smoothed routes, winding, portal degeneracies, obstacle corners, ramps and stacked floors")
}
