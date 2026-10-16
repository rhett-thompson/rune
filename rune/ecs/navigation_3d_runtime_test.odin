package ecs

import "core:testing"
import "core:encoding/json"
import "rune:navigation"

@(test)
runtime_navigation_surface_json_and_source_contract :: proc(t:^testing.T) {
	for text in ([]string{`{"runtime":true}`,`{"runtime":true,"asset":""}`,`{"asset":"level.navmesh.json"}`}) {
		value:json.Value
		assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
		_,valid:=nav_component_3d_from_json(value,NavMesh3D)
		testing.expect(t,valid,text)
	}
	for text in ([]string{`{}`,`{"runtime":false}`,`{"runtime":true,"asset":"level.navmesh.json"}`,`{"runtime":"true"}`}) {
		value:json.Value
		assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
		_,valid:=nav_component_3d_from_json(value,NavMesh3D)
		testing.expect(t,!valid,text)
	}
}

@(test)
runtime_navigation_surface_borrows_geometry_and_leaves_owner_alive :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	// Stack storage makes accidental ownership transfer/freeing fail immediately.
	vertices:=[3][3]f32{{0,0,0},{0,0,4},{4,0,0}}
	triangles:=[1]navigation.Triangle_3D{{vertices={0,1,2},neighbors={-1,-1,-1},normal={0,1,0},center={4.0/3,0,4.0/3}}}
	mesh:=navigation.Mesh_3D{vertices=vertices[:],triangles=triangles[:],agent_height=2}
	e:=create_entity(&w)
	assert(add(&w,&r,e,NavMesh3D{runtime=true}))
	_,ready:=navigation_mesh_3d(&w,e)
	testing.expect(t,!ready,"a runtime component is unavailable until bound")
	testing.expect(t,set_navigation_mesh_3d(&w,e,mesh))
	bound,found:=navigation_mesh_3d(&w,e)
	testing.expect(t,found && raw_data(bound.vertices)==raw_data(mesh.vertices) && raw_data(bound.triangles)==raw_data(mesh.triangles),
		"binding retains the same geometry without copying")
	revision,revision_ready:=navigation_mesh_revision_3d(&w,e)
	testing.expect(t,revision_ready && revision>0)
	sync_navigation_3d(&w,nil)
	testing.expect(t,w.navigation_3d.meshes[e].revision==revision,"asset sync leaves runtime bindings alone")
	testing.expect(t,set_navigation_triangle_blocked_3d(&w,e,0,true))
	blocked_revision,blocked_ready:=navigation_mesh_revision_3d(&w,e)
	testing.expect(t,triangles[0].blocked && blocked_ready && blocked_revision>revision,"blocking affects owner flags and invalidates routes")
	assert(clear_navigation_mesh_3d(&w,e))
	_,ready=navigation_mesh_3d(&w,e)
	testing.expect(t,!ready && vertices[2]==([3]f32{4,0,0}) && triangles[0].blocked,"clear removes only the borrowed binding")
	cleared_revision,cleared_ready:=navigation_mesh_revision_3d(&w,e)
	testing.expect(t,!cleared_ready && cleared_revision==0,"unbound surfaces have no usable revision")
	assert(set_navigation_mesh_3d(&w,e,mesh))
	rebound_revision,rebound_ready:=navigation_mesh_revision_3d(&w,e)
	testing.expect(t,rebound_ready && rebound_revision>blocked_revision,"replacement exposes a new revision")
	assert(remove_component(&w,e,"NavMesh3D"))
	testing.expect(t,len(w.navigation_3d.meshes)==0 && triangles[0].blocked,"component removal does not free owner arrays")
	assert(add(&w,&r,e,NavMesh3D{runtime=true}))
	assert(set_navigation_mesh_3d(&w,e,mesh))
	// The deferred world destruction must also leave borrowed stack arrays alone.
}

@(test)
runtime_navigation_rebinding_invalidates_routes_and_preserves_target :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	mesh,error:=navigation.build_mesh_3d({version=1,agent_height=2,vertices=[][3]f32{{0,0,0},{0,0,4},{4,0,0}},triangles=[][3]i32{{0,1,2}}})
	assert(error=="")
	defer navigation.destroy_mesh_3d(&mesh)
	e:=create_entity(&w)
	assert(set_entity_metadata(&w,e,"runtime_surface","","",Default_Layer_Mask))
	assert(add(&w,&r,e,NavMesh3D{runtime=true}))
	assert(set_navigation_mesh_3d(&w,e,mesh))
	// Clear before the mesh owner's deferred destruction (the world dies later).
	defer clear_navigation_mesh_3d(&w,e)
	agent:=create_entity(&w)
	pose:=default_transform();pose.position={0.5,0,0.5}
	assert(add(&w,&r,agent,pose))
	config:=default_nav_agent_3d();config.mesh={id="runtime_surface"};config.radius=0;config.height=1;config.repath_interval=60
	assert(add(&w,&r,agent,config))
	assert(set_navigation_target_3d(&w,agent,{2,0,0.5}))
	update_navigation_3d(&w,0.1)
	state,_:=get_navigation_state_3d(&w,agent)
	testing.expect(t,state.status==.Moving && state.path_status==.Complete)
	first_revision:=w.navigation_3d.agents[agent].revision
	assert(clear_navigation_mesh_3d(&w,e))
	update_navigation_3d(&w,0.1)
	state,_=get_navigation_state_3d(&w,agent)
	testing.expect(t,state.status==.Unavailable && state.has_target,"clearing stops agents without discarding destinations")
	assert(set_navigation_mesh_3d(&w,e,mesh))
	assert(set_navigation_triangle_blocked_3d(&w,e,0,true))
	update_navigation_3d(&w,0.1)
	state,_=get_navigation_state_3d(&w,agent)
	testing.expect(t,state.status==.No_Path && w.navigation_3d.agents[agent].revision>first_revision,
		"rebound geometry forces a fresh query before the ordinary repath timer")
	assert(set_navigation_triangle_blocked_3d(&w,e,0,false))
	update_navigation_3d(&w,0.1)
	state,_=get_navigation_state_3d(&w,agent)
	testing.expect(t,state.status==.Moving && state.path_status==.Complete)
	assert(set_enabled(&w,e,false))
	_,ready:=navigation_mesh_3d(&w,e)
	testing.expect(t,!ready,"runtime surfaces respect hierarchy activation")
	_,revision_ready:=navigation_mesh_revision_3d(&w,e)
	testing.expect(t,!revision_ready,"revision readiness matches mesh readiness")
}
