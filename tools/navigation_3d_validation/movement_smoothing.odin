package main

import "core:fmt"
import "core:strings"
import "rune:ecs"
import "rune:navigation"

validate_smoothed_movement :: proc() {
	for drive_controller in ([]bool{false,true}) {
		for repath_interval in ([]f32{0.1,30}) {
			validate_smoothed_agent(drive_controller,repath_interval)
		}
	}
	fmt.println("PASS straight native and Transform movement across coarse triangles, periodic repathing and stable arrival")
}

validate_smoothed_agent :: proc(drive_controller:bool,repath_interval:f32) {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	mesh_entity,agent:=ecs.create_entity(&w),ecs.create_entity(&w)
	assert(ecs.set_entity_metadata(&w,mesh_entity,"navigation","","",ecs.Default_Layer_Mask))
	asset:="movement-fixture.navmesh.json"
	assert(ecs.add(&w,&r,mesh_entity,ecs.NavMesh3D{asset=asset}))
	// Four coarse rectangles stand in for a simplified planar floor. A straight
	// route at z=2 crosses both long diagonals and rectangle boundaries away
	// from their midpoints, exposing triangle-driven detours and repath turns.
	vertices:=make([dynamic][3]f32,context.temp_allocator)
	triangles:=make([dynamic][3]i32,context.temp_allocator)
	for column in 0..=4 {
		x:=f32(-8+column*4)
		append(&vertices,[3]f32{x,0,-4},[3]f32{x,0,4})
	}
	for column in 0..<4 {
		left,right:=i32(column*2),i32((column+1)*2)
		append(&triangles,[3]i32{left,right,right+1},[3]i32{left,right+1,left+1})
	}
	mesh,error:=navigation.build_mesh_3d({version=1,agent_radius=0.35,agent_height=1.8,
		vertices=vertices[:],triangles=triangles[:]})
	assert(error=="",error)
	ecs.ensure_navigation_3d(&w)
	w.navigation_3d.meshes[mesh_entity]={mesh=mesh,source=strings.clone(asset) or_else "",revision=1}
	start,goal:=[3]f32{-7,0,2},[3]f32{7,0,2}
	pose:=ecs.default_transform();pose.position=start
	assert(ecs.add(&w,&r,agent,pose))
	config:=ecs.default_nav_agent_3d()
	config.mesh={id="navigation"};config.radius=0.35
	config.drive_controller=drive_controller;config.repath_interval=repath_interval
	assert(ecs.add(&w,&r,agent,config))
	if drive_controller {
		motor:=ecs.default_character_controller_3d();motor.move_speed=config.speed
		assert(ecs.add(&w,&r,agent,motor))
		floor:=ecs.create_entity(&w)
		floor_pose:=ecs.default_transform();floor_pose.position={0,-0.25,0}
		assert(ecs.add(&w,&r,floor,floor_pose))
		assert(ecs.add(&w,&r,floor,ecs.BoxCollider{size={18,0.5,10},is_static=true,friction=0.6}))
	}
	assert(ecs.set_navigation_target_3d(&w,agent,goal))
	dt:=f32(1.0/60)
	previous:=start
	previous_route_start:=start
	refreshed_routes:=0
	arrived:=false
	for _ in 0..<600 {
		ecs.update_navigation_3d(&w,dt)
		state,_:=ecs.get_navigation_state_3d(&w,agent)
		assert(state.status==.Moving || state.status==.Arrived,"coarse planar route remains available")
		if len(state.path)>0 && navigation.distance_3d(state.path[0],previous_route_start)>0.001 {
			refreshed_routes+=1;previous_route_start=state.path[0]
		}
		if state.status==.Moving && navigation.length_3d(state.desired_velocity)>0 {
			assert(state.desired_velocity.x>0 && abs(state.desired_velocity.z)<0.001,
				"steering stays aligned with the direct route across triangle boundaries and repaths")
		}
		if drive_controller {ecs.physics_3d_update(&w,dt)}
		pose,_=ecs.get_transform(&w,agent)
		assert(abs(pose.position.z-start.z)<0.01,"flat-floor movement does not zigzag toward triangle midpoints")
		assert(pose.position.x>=previous.x-0.001,"periodic repathing does not reverse progress")
		assert(navigation.distance_3d(previous,pose.position)<=config.speed*dt+0.01,"movement respects agent speed")
		_,_,on_mesh:=navigation.project_point_3d(&mesh,pose.position,0.02)
		assert(on_mesh,"straight movement remains on the walkable floor")
		previous=pose.position
		if state.status==.Arrived {arrived=true;break}
	}
	assert(arrived,"native and Transform agents reach the direct route's goal")
	assert(navigation.distance_3d(pose.position,goal)<=config.arrival_distance+0.02)
	if repath_interval<1 {assert(refreshed_routes>3,"movement stability is exercised across multiple path refreshes")}
	for _ in 0..<120 {
		ecs.update_navigation_3d(&w,dt)
		if drive_controller {ecs.physics_3d_update(&w,dt)}
		state,_:=ecs.get_navigation_state_3d(&w,agent)
		pose,_=ecs.get_transform(&w,agent)
		assert(state.status==.Arrived && navigation.distance_3d(pose.position,goal)<=config.arrival_distance+0.02,
			"arrival stays settled through further periodic repaths")
	}
}
