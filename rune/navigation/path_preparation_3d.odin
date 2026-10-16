package navigation

import "core:mem"

// Owns immutable clearance geometry and corner templates for one connected
// component and agent footprint. Mesh arrays are borrowed by value: keep them
// alive and unchanged until destruction. Rebuild after any geometry/blocking
// change. Searches keep their scores, parents, portals and paths independent.
Clearance_Preparation_3D :: struct {
	mesh:Mesh_3D,
	query:Clearance_Query_3D,
	arena:mem.Dynamic_Arena,
	allocator:mem.Allocator,
}

create_clearance_preparation_3d :: proc(mesh:Mesh_3D,options:Path_Options_3D,start_triangle:i32,allocator:=context.allocator) -> ^Clearance_Preparation_3D {
	borrowed:=mesh
	if !path_options_valid_3d(options) || options.height>mesh.agent_height+1e-6 ||
		options.radius<=mesh.agent_radius+1e-6 || !triangle_allowed_3d(&borrowed,start_triangle,options.max_slope) {return nil}
	preparation,err:=mem.new(Clearance_Preparation_3D,allocator)
	if err!=nil {return nil}
	preparation.mesh=mesh;preparation.allocator=allocator
	mem.dynamic_arena_init(&preparation.arena,block_allocator=allocator,array_allocator=allocator)
	a:=mem.dynamic_arena_allocator(&preparation.arena)
	preparation.query=clearance_query_3d(&preparation.mesh,options,start_triangle,a)
	q:=&preparation.query
	// Queries reserve these same endpoint indices before adding corners.
	clearance_add_node_3d(q,{});clearance_add_node_3d(q,{})
	clearance_add_corners_3d(q)
	for connected,i in q.component {if connected {clearance_triangle_edges_3d(q,i32(i))}}
	return preparation
}

destroy_clearance_preparation_3d :: proc(preparation:^Clearance_Preparation_3D) {
	if preparation==nil {return}
	a:=preparation.allocator
	mem.dynamic_arena_destroy(&preparation.arena)
	mem.free(preparation,a)
}

clearance_preparation_matches_3d :: proc(preparation:^Clearance_Preparation_3D,mesh:^Mesh_3D,options:Path_Options_3D,start_triangle:i32) -> bool {
	if preparation==nil || start_triangle<0 || int(start_triangle)>=len(preparation.query.component) {return false}
	stored:=&preparation.mesh;q:=&preparation.query
	return raw_data(stored.vertices)==raw_data(mesh.vertices) && len(stored.vertices)==len(mesh.vertices) &&
		raw_data(stored.triangles)==raw_data(mesh.triangles) && len(stored.triangles)==len(mesh.triangles) &&
		stored.agent_radius==mesh.agent_radius && stored.agent_height==mesh.agent_height &&
		q.options.radius==options.radius && q.options.max_slope==options.max_slope && q.component[start_triangle]
}

clearance_prepared_query_3d :: proc(preparation:^Clearance_Preparation_3D,options:Path_Options_3D,start,goal:[3]f32,si,gi:i32) -> Clearance_Query_3D {
	a:=context.temp_allocator
	q:=preparation.query;q.options=options;q.allocator=a
	q.nodes=make([dynamic]Clearance_Node_3D,len(preparation.query.nodes),len(preparation.query.nodes)+64,a)
	copy(q.nodes[:],preparation.query.nodes[:])
	q.nodes[0].point=start;q.nodes[1].point=goal
	for triangle,endpoint in ([2]i32{si,gi}) {
		q.nodes[endpoint].members=make([dynamic]i32,0,1,a)
		append(&q.nodes[endpoint].members,triangle)
	}
	q.triangle_nodes=make([][dynamic]i32,len(q.mesh.triangles),a)
	for members,i in preparation.query.triangle_nodes {
		if len(members)==0 && i!=int(si) && i!=int(gi) {continue}
		q.triangle_nodes[i]=make([dynamic]i32,0,len(members)+8,a)
		// Preserve uncached membership order: endpoints precede corner nodes.
		if i==int(si) {append(&q.triangle_nodes[i],0)}
		if i==int(gi) {append(&q.triangle_nodes[i],1)}
		append(&q.triangle_nodes[i],..members[:])
	}
	q.portals=make(map[Edge_3D]bool,a)
	return q
}
