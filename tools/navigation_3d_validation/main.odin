package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import "rune:assets"
import "rune:ecs"
import "rune:navigation"
import "rune:scene"
import "rune:validation"

fixture_serial:i64
parse :: proc(text:string) -> json.Value {
	value:json.Value
	assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
	return value
}
write_fixture :: proc(text:[]u8) {
	assert(os.write_entire_file("build/navigation-test.navmesh.json",text)==nil)
	fixture_serial+=1
	stamp:=time.unix(1750000000+fixture_serial,0)
	assert(os.change_times("build/navigation-test.navmesh.json",stamp,stamp)==nil)
}
entity :: proc(w:^ecs.World,id:string) -> ecs.Entity {e,ok:=ecs.find_entity_by_id(w,id);assert(ok);return e}

main :: proc() {
	validate_geometry()
	validate_agents()
	validate_assets()
	fmt.println("Navigation 3D validation passed: topology, ramps, stacked floors, corridor containment, clearance, blocked routes, movement, controller integration, lifecycle, reload and authoring")
	for arg in os.args[1:] {if arg=="--runtime" {validate_runtime()}}
}
validate_geometry :: proc() {
	mesh,error:=navigation.load_mesh_3d("examples/navigation_3d/course.navmesh.json")
	assert(error=="",error);defer navigation.destroy_mesh_3d(&mesh)
	path:=navigation.find_path_3d(&mesh,{-7,0,3},{7,2,3})
	assert(path.status==.Complete && len(path.points)>2);defer navigation.destroy_path_3d(&path)
	for i in 0..<len(path.triangles) {
		for sample in 0..=10 {
			p:=path.points[i]+(path.points[i+1]-path.points[i])*(f32(sample)/10)
			nearest:=navigation.closest_triangle_3d(&mesh,path.triangles[i],p)
			assert(navigation.distance_3d(nearest,p)<0.001,"every path segment lies in its corridor triangle")
		}
	}
	unreachable:=navigation.find_path_3d(&mesh,{-7,0,3},{11,0,1})
	assert(unreachable.status==.Unreachable && len(unreachable.points)==0)
	bad:=navigation.find_path_3d(&mesh,{-7,0,3},{7,2,3},{radius=0.5,height=1.8,max_slope=45,max_projection=1})
	assert(bad.status==.Insufficient_Clearance)
	steep:=navigation.find_path_3d(&mesh,{-7,0,3},{7,2,3},{radius=0.3,height=1.8,max_slope=10,max_projection=1})
	assert(steep.status==.Unreachable)
	off:=navigation.find_path_3d(&mesh,{100,0,0},{7,2,3})
	assert(off.status==.Start_Off_Mesh)
	for &triangle in mesh.triangles {if triangle.center.x>-2 && triangle.center.x<0 {triangle.blocked=true}}
	closed:=navigation.find_path_3d(&mesh,{-7,0,3},{7,2,3})
	assert(closed.status==.Unreachable)
	// Overlapping floors use XYZ distance and ray depth, never just XZ.
	data:=navigation.Mesh_Data_3D{version=1,agent_radius=0.5,agent_height=2,
		vertices=[][3]f32{{0,0,0},{2,0,0},{0,0,2},{0,3,0},{2,3,0},{0,3,2}},
		triangles=[][3]i32{{0,1,2},{3,4,5}}}
	stacked,stack_error:=navigation.build_mesh_3d(data)
	assert(stack_error=="");defer navigation.destroy_mesh_3d(&stacked)
	p,index,found:=navigation.project_point_3d(&stacked,{0.5,2.9,0.5},0.2)
	assert(found && index==1 && abs(p.y-3)<1e-5)
	p,index,found=navigation.raycast_mesh_3d(&stacked,{0.5,10,0.5},{0,-20,0})
	assert(found && index==1 && abs(p.y-3)<1e-5)
	cross_floor:=navigation.find_path_3d(&stacked,{0.5,0,0.5},{0.5,3,0.5})
	assert(cross_floor.status==.Unreachable)
	data.triangles=[][3]i32{{0,1,99}}
	_,error=navigation.build_mesh_3d(data);assert(error!="")
	data.triangles=[][3]i32{{0,0,1}}
	_,error=navigation.build_mesh_3d(data);assert(error!="")
	data.triangles=[][3]i32{{0,1,2},{2,1,0}}
	_,error=navigation.build_mesh_3d(data);assert(error!="")
	data.triangles=[][3]i32{{0,1,2},{0,1,5}}
	_,error=navigation.build_mesh_3d(data);assert(error!="","same-side shared faces must not connect")
	fmt.println("PASS navmesh geometry, complete paths, clearance, slope limits and disconnected floors")
}

validate_agents :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w,loaded:=scene.load("examples/navigation_3d/scenes/main.scene.json",&r)
	assert(loaded,scene.last_load_error());defer ecs.destroy(&w)
	m:=assets.Asset_Manager{root="examples/navigation_3d",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
	defer assets.shutdown(&m)
	ecs.sync_navigation_3d(&w,&m)
	agent,mesh_entity:=entity(&w,"agent"),entity(&w,"navigation")
	config,_:=ecs.get(&w,agent,ecs.NavAgent3D)
	invalid:=config;invalid.speed=-1
	assert(!ecs.set(&w,agent,invalid))
	invalid=config;invalid.repath_interval=0
	assert(!ecs.set(&w,agent,invalid))
	assert(!ecs.add_component(&w,&r,agent,"NavAgent3D",parse(`{"mesh":{"id":"navigation"},"speed":-1}`)))
	assert(!ecs.add_component(&w,&r,agent,"NavAgent3D",parse(`{"mesh":{"id":"navigation"},"unknown":1}`)))
	assert(ecs.set_navigation_target_3d(&w,agent,{7,2,3}))
	assert(ecs.add_component(&w,&r,agent,"SphereCollider",parse(`{"radius":0.5}`)))
	ecs.update_navigation_3d(&w,1.0/60)
	invalid_state,_:=ecs.get_navigation_state_3d(&w,agent);assert(invalid_state.status==.Unavailable)
	assert(ecs.remove_component(&w,agent,"SphereCollider"))
	for _ in 0..<1500 {ecs.update_navigation_3d(&w,1.0/60);ecs.physics_3d_update(&w,1.0/60)}
	state,_:=ecs.get_navigation_state_3d(&w,agent)
	pose,_:=ecs.get_transform(&w,agent)
	fmt.println("Controller final",pose.position,state.status)
	assert(state.status==.Arrived && navigation.distance_3d(pose.position,{7,2,3})<0.3,"native motor follows ramp to upper floor")
	assert(ecs.stop_navigation_3d(&w,agent))
	assert(ecs.remove_component(&w,agent,"CharacterController3D"))
	config.drive_controller=false
	assert(ecs.set(&w,agent,config))
	pose.position={-7,0,3};assert(ecs.set_transform(&w,agent,pose))
	assert(ecs.set_navigation_target_3d(&w,agent,{7,2,3}))
	for _ in 0..<900 {
		before,_:=ecs.get_transform(&w,agent)
		ecs.update_navigation_3d(&w,1.0/60)
		after,_:=ecs.get_transform(&w,agent)
		assert(navigation.distance_3d(before.position,after.position)<=config.speed/60+0.001)
		mesh,_:=ecs.navigation_mesh_3d(&w,mesh_entity)
		_,_,on_mesh:=navigation.project_point_3d(&mesh,after.position,0.001)
		assert(on_mesh,"transform agent stays on surface")
	}
	state,_=ecs.get_navigation_state_3d(&w,agent);assert(state.status==.Arrived)
	// Teleporting to a disconnected island must stop immediately, even before
	// the ordinary repath interval expires.
	pose,_=ecs.get_transform(&w,agent);pose.position={11,0,1};assert(ecs.set_transform(&w,agent,pose))
	ecs.update_navigation_3d(&w,1.0/60)
	state,_=ecs.get_navigation_state_3d(&w,agent);assert(state.status==.No_Path)
	pose.position={7,2,3};assert(ecs.set_transform(&w,agent,pose))
	assert(ecs.set_navigation_target_3d(&w,agent,{-7,0,3}))
	ecs.set_enabled(&w,agent,false)
	before,_:=ecs.get_transform(&w,agent)
	ecs.update_navigation_3d(&w,1)
	after,_:=ecs.get_transform(&w,agent)
	state,_=ecs.get_navigation_state_3d(&w,agent)
	assert(before==after && state.status==.Disabled)
	ecs.set_enabled(&w,agent,true)
	mesh,_:=ecs.navigation_mesh_3d(&w,mesh_entity)
	for t,i in mesh.triangles {if t.center.x>-2 && t.center.x<0 {assert(ecs.set_navigation_triangle_blocked_3d(&w,mesh_entity,i32(i),true))}}
	ecs.update_navigation_3d(&w,1.0/60)
	state,_=ecs.get_navigation_state_3d(&w,agent);assert(state.status==.No_Path)
	for t,i in mesh.triangles {if t.blocked {assert(ecs.set_navigation_triangle_blocked_3d(&w,mesh_entity,i32(i),false))}}
	ecs.update_navigation_3d(&w,1.0/60)
	state,_=ecs.get_navigation_state_3d(&w,agent);assert(state.status==.Moving)
	ecs.set_enabled(&w,mesh_entity,false);ecs.update_navigation_3d(&w,1.0/60)
	state,_=ecs.get_navigation_state_3d(&w,agent);assert(state.status==.Unavailable)
	ecs.set_enabled(&w,mesh_entity,true)
	// Structural reload is distinct from value reload.
	snapshot,snapshot_ok:=scene.load("examples/navigation_3d/scenes/main.scene.json",&r)
	assert(snapshot_ok);defer ecs.destroy(&snapshot)
	assert(ecs.apply_value_snapshot(&w,&snapshot)==false,"component removal makes this a structural change")
	assert(ecs.remove_component(&snapshot,entity(&snapshot,"agent"),"CharacterController3D"))
	// Match the component-type history from the earlier invalid-motor probe.
	assert(ecs.add_component(&snapshot,&r,entity(&snapshot,"agent"),"SphereCollider",parse(`{"radius":0.5}`)))
	assert(ecs.remove_component(&snapshot,entity(&snapshot,"agent"),"SphereCollider"))
	assert(ecs.add_component(&snapshot,&r,entity(&snapshot,"agent"),"NavAgent3D",parse(`{"mesh":{"id":"navigation"},"speed":2}`)))
	assert(ecs.apply_value_snapshot(&w,&snapshot),"value-only reload retains the world")
	state,_=ecs.get_navigation_state_3d(&w,agent)
	assert(state.has_target && state.target==([3]f32{-7,0,3}),"value reload preserves the destination")
	updated_actual,_:=ecs.get(&w,agent,ecs.NavAgent3D);assert(updated_actual.speed==2)
	ecs.stop_navigation_3d(&w,agent)
	assert(ecs.remove_component(&w,agent,"NavAgent3D"))
	assert(len(w.navigation_3d.agents)==0)
	assert(ecs.destroy_entity(&w,mesh_entity));assert(len(w.navigation_3d.meshes)==0)
	fmt.println("PASS native and Transform agents, blocked route replanning, activation and component removal")
}

validate_assets :: proc() {
	original,err:=os.read_entire_file("examples/navigation_3d/course.navmesh.json",context.temp_allocator);assert(err==nil)
	write_fixture(original)
	m:=assets.Asset_Manager{root=".",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()};defer assets.shutdown(&m)
	_,revision,ready:=assets.navmesh_data(&m,"build/navigation-test.navmesh.json");assert(ready)
	write_fixture(transmute([]u8)string("{broken"));assets.refresh_navmeshes(&m)
	mesh,unchanged,still_ready:=assets.navmesh_data(&m,"build/navigation-test.navmesh.json")
	assert(still_ready && unchanged==revision && len(mesh.triangles)>0)
	data:navigation.Mesh_Data_3D
	assert(json.unmarshal(original,&data,allocator=context.temp_allocator)==nil)
	for &v in data.vertices {v.y+=1}
	modified,marshal_error:=json.marshal(data,allocator=context.temp_allocator);assert(marshal_error==nil)
	write_fixture(modified);assets.refresh_navmeshes(&m)
	new_revision:u64
	mesh,new_revision,ready=assets.navmesh_data(&m,"build/navigation-test.navmesh.json")
	assert(ready && new_revision>revision && mesh.vertices[0].y==1)
	// Worlds own their blocked flags and data independently from asset reloads.
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	first,second:=ecs.create_entity(&w),ecs.create_entity(&w)
	assert(ecs.add(&w,&r,first,ecs.NavMesh3D{"build/navigation-test.navmesh.json"}))
	assert(ecs.add(&w,&r,second,ecs.NavMesh3D{"build/navigation-test.navmesh.json"}))
	ecs.sync_navigation_3d(&w,&m)
	assert(ecs.set_navigation_triangle_blocked_3d(&w,first,0,true))
	other,_:=ecs.navigation_mesh_3d(&w,second);assert(!other.triangles[0].blocked)
	write_fixture(original);assets.refresh_navmeshes(&m);ecs.sync_navigation_3d(&w,&m)
	reloaded,reloaded_ok:=ecs.navigation_mesh_3d(&w,first)
	assert(reloaded_ok && reloaded.vertices[0].y==0 && !reloaded.triangles[0].blocked)
	report:=validation.validate_project("examples/navigation_3d/project.json");defer validation.destroy_report(&report)
	assert(validation.is_valid(&report))
	fmt.println("PASS navmesh cache recovery, hot reload revisions and project validation")
}
