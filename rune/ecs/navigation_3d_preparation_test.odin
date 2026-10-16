package ecs

import "core:testing"
import "rune:navigation"

@(test)
navigation_preparation_cache_reuses_components_bounds_memory_and_invalidates :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	mesh,error:=navigation.build_mesh_3d({version=1,agent_radius=0.34,agent_height=2,
		vertices=[][3]f32{{0,0,0},{20,0,0},{20,0,20},{0,0,20},{30,0,0},{50,0,0},{50,0,20},{30,0,20}},
		triangles=[][3]i32{{0,1,2},{0,2,3},{4,5,6},{4,6,7}}})
	if !testing.expect(t,error=="",error) {return};defer navigation.destroy_mesh_3d(&mesh)
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	e:=create_entity(&w);assert(add(&w,&r,e,NavMesh3D{runtime=true}));assert(set_navigation_mesh_3d(&w,e,mesh))
	options:=navigation.Path_Options_3D{radius=1.2,height=1.5,max_slope=30,max_projection=2}
	start,goal:=[3]f32{3,0,3},[3]f32{17,0,17}
	testing.expect(t,prepare_navigation_path_3d(&w,e,start,options))
	preparation:=w.navigation_3d.meshes[e].clearance_preparations[0]
	path:=find_navigation_path_3d(&w,e,start,goal,options)
	testing.expect(t,path.status==.Complete,"prepared runtime mesh returns an owned path")
	navigation.destroy_path_3d(&path)
	changed:=options;changed.height=1;changed.max_projection=3
	testing.expect(t,prepare_navigation_path_3d(&w,e,start,changed) && w.navigation_3d.meshes[e].clearance_preparation_count==1 && w.navigation_3d.meshes[e].clearance_preparations[0]==preparation,
		"height and endpoint projection limits reuse the same footprint preparation")
	testing.expect(t,prepare_navigation_path_3d(&w,e,{33,0,3},options) && w.navigation_3d.meshes[e].clearance_preparation_count==2,"disconnected components retain separate boundaries")
	// Growing the runtime map must not move arenas or the borrowed mesh value.
	for _ in 0..<48 {
		other:=create_entity(&w);assert(add(&w,&r,other,NavMesh3D{runtime=true}));assert(set_navigation_mesh_3d(&w,other,mesh))
	}
	path=find_navigation_path_3d(&w,e,start,goal,options)
	testing.expect(t,path.status==.Complete && w.navigation_3d.meshes[e].clearance_preparations[0]==preparation,"map growth preserves heap-owned preparation")
	navigation.destroy_path_3d(&path)
	changed=options;changed.max_slope=20;testing.expect(t,prepare_navigation_path_3d(&w,e,start,changed))
	changed=options;changed.radius=1.3;testing.expect(t,prepare_navigation_path_3d(&w,e,start,changed))
	testing.expect(t,w.navigation_3d.meshes[e].clearance_preparation_count==Navigation_Clearance_Cache_Limit_3D)
	changed.radius=1.4
	testing.expect(t,!prepare_navigation_path_3d(&w,e,start,changed),"the fixed cache limit bounds retained memory")
	path=find_navigation_path_3d(&w,e,start,goal,changed)
	testing.expect(t,path.status==.Complete && w.navigation_3d.meshes[e].clearance_preparation_count==Navigation_Clearance_Cache_Limit_3D,"queries beyond the cache limit use the ordinary scratch path")
	navigation.destroy_path_3d(&path)
	assert(set_navigation_triangle_blocked_3d(&w,e,0,true))
	testing.expect(t,w.navigation_3d.meshes[e].clearance_preparation_count==0 && mesh.triangles[0].blocked,"blocking destroys every stale component preparation before the next query")
	assert(set_navigation_triangle_blocked_3d(&w,e,1,true))
	path=find_navigation_path_3d(&w,e,start,goal,options)
	testing.expect(t,path.status==.Start_Off_Mesh,"a cached route cannot survive blocked source geometry")
	navigation.destroy_path_3d(&path)
	assert(set_navigation_triangle_blocked_3d(&w,e,0,false));assert(set_navigation_triangle_blocked_3d(&w,e,1,false))
	testing.expect(t,prepare_navigation_path_3d(&w,e,start,options))
	assert(set_navigation_mesh_3d(&w,e,mesh))
	testing.expect(t,w.navigation_3d.meshes[e].clearance_preparation_count==0,"rebinding destroys preparations even when the owner's arrays are reused")
	testing.expect(t,prepare_navigation_path_3d(&w,e,start,options));assert(clear_navigation_mesh_3d(&w,e))
	testing.expect(t,mesh.vertices[2]==([3]f32{20,0,20}) && !mesh.triangles[0].blocked,"clearing preparation never frees or changes borrowed geometry")
	assert(set_navigation_mesh_3d(&w,e,mesh));testing.expect(t,prepare_navigation_path_3d(&w,e,start,options))
	assert(remove_component(&w,e,"NavMesh3D"))
	_,found:=w.navigation_3d.meshes[e]
	testing.expect(t,!found && mesh.vertices[2]==([3]f32{20,0,20}),"component removal releases preparation and preserves owner arrays")
}
