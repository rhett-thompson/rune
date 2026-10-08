package main

import "core:fmt"
import "core:math"
import "core:strings"
import "rune:ecs"
import "rune:navigation"

movement_options_mesh :: proc(world:^ecs.World,registry:^ecs.Component_Registry,vertices:[][3]f32,triangles:[][3]i32) -> ecs.Entity {
	mesh_entity:=ecs.create_entity(world)
	assert(ecs.set_entity_metadata(world,mesh_entity,"navigation","","",ecs.Default_Layer_Mask))
	asset:="movement-options-fixture.navmesh.json"
	assert(ecs.add(world,registry,mesh_entity,ecs.NavMesh3D{asset=asset}))
	mesh,error:=navigation.build_mesh_3d({version=1,agent_radius=0.35,agent_height=1.8,vertices=vertices,triangles=triangles})
	assert(error=="",error)
	ecs.ensure_navigation_3d(world)
	world.navigation_3d.meshes[mesh_entity]={mesh=mesh,source=strings.clone(asset) or_else "",revision=1}
	return mesh_entity
}

movement_options_floor :: proc(world:^ecs.World,registry:^ecs.Component_Registry) -> ecs.Entity {
	vertices:=make([dynamic][3]f32,context.temp_allocator)
	triangles:=make([dynamic][3]i32,context.temp_allocator)
	for column in 0..=8 {
		x:=f32(-40+column*10)
		append(&vertices,[3]f32{x,0,-12},[3]f32{x,0,12})
	}
	for column in 0..<8 {
		left,right:=i32(column*2),i32((column+1)*2)
		append(&triangles,[3]i32{left,right,right+1},[3]i32{left,right+1,left+1})
	}
	mesh_entity:=movement_options_mesh(world,registry,vertices[:],triangles[:])
	floor:=ecs.create_entity(world)
	pose:=ecs.default_transform();pose.position={0,-0.25,0}
	assert(ecs.add(world,registry,floor,pose))
	assert(ecs.add(world,registry,floor,ecs.BoxCollider{size={82,0.5,26},is_static=true,friction=0.6}))
	return mesh_entity
}

movement_options_agent :: proc(world:^ecs.World,registry:^ecs.Component_Registry,start:[3]f32,config:ecs.NavAgent3D,yaw:f32=0) -> ecs.Entity {
	agent:=ecs.create_entity(world)
	pose:=ecs.default_transform();pose.position=start;pose.rotation.y=yaw
	assert(ecs.add(world,registry,agent,pose))
	assert(ecs.add(world,registry,agent,config))
	if config.drive_controller {
		motor:=ecs.default_character_controller_3d()
		motor.move_speed=config.speed;motor.acceleration=max(config.acceleration,f32(0.1));motor.braking=max(config.braking,f32(0.1))
		assert(ecs.add(world,registry,agent,motor))
	}
	return agent
}

movement_options_config :: proc(drive_controller:bool=false) -> ecs.NavAgent3D {
	config:=ecs.default_nav_agent_3d()
	config.mesh={id="navigation"};config.radius=0.35;config.repath_interval=30
	config.drive_controller=drive_controller
	return config
}

movement_options_tick :: proc(world:^ecs.World,agent:ecs.Entity,dt:f32) -> (ecs.Transform,ecs.Nav_Agent_State_3D) {
	ecs.update_navigation_3d(world,dt)
	config,_:=ecs.get(world,agent,ecs.NavAgent3D)
	if config.drive_controller {ecs.physics_3d_update(world,dt)}
	pose,_:=ecs.get_transform(world,agent)
	state,_:=ecs.get_navigation_state_3d(world,agent)
	return pose,state
}

movement_options_horizontal :: proc(v:[3]f32) -> f32 {return math.sqrt(v.x*v.x+v.z*v.z)}

movement_options_yaw_delta :: proc(before,after:f32) -> f32 {
	delta:=after-before
	for delta>180 {delta-=360}
	for delta< -180 {delta+=360}
	return delta
}

validate_movement_options :: proc() {
	validate_movement_options_authoring()
	for drive_controller in ([]bool{false,true}) {
		validate_movement_options_rotation(drive_controller,true)
		validate_movement_options_rotation(drive_controller,false)
		for stopping_distance in ([]f32{0,2}) {validate_movement_options_stopping(drive_controller,stopping_distance)}
	}
	validate_movement_options_replanning()
	validate_movement_options_arrival_braking()
	validate_movement_options_corners()
	validate_movement_options_controller_corners()
	validate_movement_options_ramp()
	fmt.println("PASS movement options: bounded facing, braking and standoff, settled arrival, speed continuity, corner anticipation and ramp containment")
}

validate_movement_options_authoring :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	agent:=ecs.create_entity(&w)
	assert(ecs.add_component(&w,&r,agent,"NavAgent3D",parse(`{"mesh":{"id":"navigation"},"angular_speed":75,"update_rotation":true,"auto_braking":true,"corner_slowdown":true,"acceleration":4,"braking":2,"waypoint_distance":0.15,"stopping_distance":1.5}`)))
	config,_:=ecs.get(&w,agent,ecs.NavAgent3D)
	assert(config.angular_speed==75 && config.update_rotation && config.auto_braking && config.corner_slowdown)
	assert(config.acceleration==4 && config.braking==2 && config.waypoint_distance==0.15 && config.stopping_distance==1.5)
	for invalid in ([]string{
		`{"mesh":{"id":"navigation"},"angular_speed":-1}`,
		`{"mesh":{"id":"navigation"},"acceleration":-1}`,
		`{"mesh":{"id":"navigation"},"braking":-1}`,
		`{"mesh":{"id":"navigation"},"waypoint_distance":-1}`,
		`{"mesh":{"id":"navigation"},"stopping_distance":-1}`,
		`{"mesh":{"id":"navigation"},"update_rotation":1}`,
	}) {assert(!ecs.add_component(&w,&r,agent,"NavAgent3D",parse(invalid)),"invalid movement authoring is rejected")}
}

validate_movement_options_rotation :: proc(drive_controller,update_rotation:bool) {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	movement_options_floor(&w,&r)
	config:=movement_options_config(drive_controller)
	config.speed=0.5;config.acceleration=10;config.braking=10
	config.angular_speed=30;config.update_rotation=update_rotation
	agent:=movement_options_agent(&w,&r,{0,0,0},config,170)
	angle:=f32(-170*math.PI/180)
	goal:=[3]f32{math.sin(angle)*6,0,math.cos(angle)*6}
	assert(ecs.set_navigation_target_3d(&w,agent,goal))
	previous_yaw:=f32(170)
	dt:=f32(1.0/60)
	for _ in 0..<60 {
		pose,state:=movement_options_tick(&w,agent,dt)
		assert(state.status==.Moving)
		delta:=movement_options_yaw_delta(previous_yaw,pose.rotation.y)
		if update_rotation {
			assert(abs(delta)<=config.angular_speed*dt+0.001,"facing obeys angular speed in degrees per second")
			assert(delta>= -0.001,"facing takes the short positive arc from 170 to -170 degrees")
		} else {assert(pose.rotation.y==170,"disabled facing preserves the authored yaw")}
		assert(pose.rotation.x==0 && pose.rotation.z==0,"facing changes yaw without tilting the agent")
		previous_yaw=pose.rotation.y
	}
	if update_rotation {assert(abs(movement_options_yaw_delta(previous_yaw,-170))<0.01,"the +Z forward axis faces the movement direction")}
}

validate_movement_options_stopping :: proc(drive_controller:bool,stopping_distance:f32) {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	mesh_entity:=movement_options_floor(&w,&r)
	config:=movement_options_config(drive_controller)
	config.speed=8;config.acceleration=4;config.braking=1
	config.auto_braking=true;config.stopping_distance=stopping_distance;config.repath_interval=0.2
	start,goal:=[3]f32{-35,0,2},[3]f32{35,0,2}
	agent:=movement_options_agent(&w,&r,start,config)
	assert(ecs.set_navigation_target_3d(&w,agent,goal))
	dt:=f32(1.0/60)
	arrived,braked_early,cruised:=false,false,false
	previous:=start
	for _ in 0..<2400 {
		pose,state:=movement_options_tick(&w,agent,dt)
		assert(state.status==.Moving || state.status==.Arrived,"a low-braking route stays available through periodic replans")
		speed:=movement_options_horizontal(state.actual_velocity)
		assert(speed<=config.speed+0.05,"actual movement obeys the configured speed limit")
		assert(state.remaining_distance>=0,"remaining path distance is nonnegative")
		if speed>config.speed-0.1 {cruised=true}
		if cruised && state.desired_velocity.x<config.speed-0.25 && state.remaining_distance>stopping_distance+2 {braked_early=true}
		assert(pose.position.x>=previous.x-0.01,"predictive stopping does not repeatedly overshoot and reverse")
		assert(pose.position.x<=goal.x-stopping_distance+config.arrival_distance+0.08,"low braking stops before overshooting the destination tolerance")
		assert(abs(pose.position.z-start.z)<0.02,"braking keeps steering on the straight route")
		mesh,_:=ecs.navigation_mesh_3d(&w,mesh_entity)
		_,_,on_mesh:=navigation.project_point_3d(&mesh,pose.position,0.25)
		assert(on_mesh,"braking movement stays on the mesh")
		previous=pose.position
		if state.status==.Arrived {
			assert(speed<=0.05+0.001,"Arrived requires an almost stopped agent")
			assert(movement_options_horizontal(pose.position-goal)<=stopping_distance+config.arrival_distance+0.03)
			assert(abs(pose.position.y-goal.y)<=0.25)
			arrived=true;break
		}
	}
	assert(cruised && braked_early,"predictive stopping is exercised after full speed and well before arrival")
	assert(arrived,"low-braking native and Transform agents settle at the destination")
	pose,_:=ecs.get_transform(&w,agent)
	settled:=pose.position
	if stopping_distance>0 {assert(movement_options_horizontal(pose.position-goal)>=stopping_distance-0.08,"stopping distance leaves the requested standoff")}
	for _ in 0..<120 {
		pose,state:=movement_options_tick(&w,agent,dt)
		assert(state.status==.Arrived && movement_options_horizontal(pose.position-settled)<0.025,"arrived agents stay settled across periodic repaths")
	}
}

validate_movement_options_replanning :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	movement_options_floor(&w,&r)
	config:=movement_options_config();config.speed=6;config.acceleration=4;config.braking=2;config.repath_interval=0.1
	agent:=movement_options_agent(&w,&r,{-30,0,2},config)
	assert(ecs.set_navigation_target_3d(&w,agent,{15,0,2}))
	dt:=f32(1.0/60)
	previous_speed:f32
	refreshed:=0
	previous_route_start:=[3]f32{-30,0,2}
	for tick in 0..<180 {
		_,state:=movement_options_tick(&w,agent,dt)
		speed:=movement_options_horizontal(state.actual_velocity)
		assert(speed<=previous_speed+config.acceleration*dt+0.01,"direct movement ramps up at its configured acceleration")
		if tick>95 {assert(speed>=config.speed-0.02,"periodic repaths preserve the direct movement speed")}
		if len(state.path)>0 && navigation.distance_3d(state.path[0],previous_route_start)>0.001 {refreshed+=1;previous_route_start=state.path[0]}
		previous_speed=speed
	}
	assert(refreshed>10,"speed continuity is checked across repeated actual replans")
	assert(ecs.set_navigation_target_3d(&w,agent,{30,0,2}))
	_,state:=movement_options_tick(&w,agent,dt)
	assert(movement_options_horizontal(state.actual_velocity)>=previous_speed-0.02,"retargeting in the travel direction preserves speed")
}

validate_movement_options_arrival_braking :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	movement_options_floor(&w,&r)
	config:=movement_options_config()
	config.speed=2;config.acceleration=4;config.braking=1;config.arrival_distance=3
	agent:=movement_options_agent(&w,&r,{-10,0,2},config)
	goal:=[3]f32{10,0,2}
	assert(ecs.set_navigation_target_3d(&w,agent,goal))
	previous:=[3]f32{-10,0,2}
	previous_speed:f32
	entered,continued,arrived:=false,false,false
	for _ in 0..<900 {
		pose,state:=movement_options_tick(&w,agent,1.0/60)
		speed:=movement_options_horizontal(state.actual_velocity)
		assert(state.status==.Moving || state.status==.Arrived)
		if entered && previous_speed>0.2 {
			assert(pose.position.x>previous.x+0.001,"direct movement continues physically braking inside arrival tolerance")
			assert(speed>=previous_speed-config.braking/60-0.002,"arrival braking limits actual deceleration")
			continued=true
		}
		if navigation.distance_3d(pose.position,goal)<=config.arrival_distance {entered=true}
		previous=pose.position;previous_speed=speed
		if state.status==.Arrived {arrived=true;assert(speed<=0.051);break}
	}
	assert(entered && continued && arrived,"direct motion settles naturally within a generous arrival radius")
}

validate_movement_options_corners :: proc() {
	for slowdown in ([]bool{false,true}) {
		r:=ecs.init_registry();assert(ecs.register_builtin_components(&r))
		w:=ecs.init()
		mesh_entity:=movement_options_mesh(&w,&r,
			[][3]f32{{-20,0,0},{4,0,0},{6,0,0},{-20,0,2},{4,0,2},{6,0,2},{4,0,20},{6,0,20}},
			[][3]i32{{0,1,4},{0,4,3},{1,2,5},{1,5,4},{4,5,7},{4,7,6}})
		config:=movement_options_config();config.speed=6;config.acceleration=12;config.braking=4;config.corner_slowdown=slowdown
		agent:=movement_options_agent(&w,&r,{-10,0,1},config)
		assert(ecs.set_navigation_target_3d(&w,agent,{5,0,12}))
		corner:=[3]f32{4,0,2}
		cruised,slowed_near_corner,arrived:=false,false,false
		for _ in 0..<900 {
			pose,state:=movement_options_tick(&w,agent,1.0/60)
			assert(state.status==.Moving || state.status==.Arrived)
			speed:=movement_options_horizontal(state.actual_velocity)
			if pose.position.x< -4 && speed>config.speed-0.1 {cruised=true}
			if pose.position.x<4 && navigation.distance_3d(pose.position,corner)<3 && speed<config.speed*0.9 {slowed_near_corner=true}
			mesh,_:=ecs.navigation_mesh_3d(&w,mesh_entity)
			_,_,on_mesh:=navigation.project_point_3d(&mesh,pose.position,0.002)
			assert(on_mesh,"corner anticipation keeps direct movement inside the legal corridor")
			if state.status==.Arrived {arrived=true;break}
		}
		assert(cruised && arrived)
		assert(slowed_near_corner==slowdown,"corner slowdown reduces speed before a real bend and is optional")
		ecs.destroy(&w);ecs.destroy_registry(&r)
	}
	// Several coarse triangle portals cross a straight route; they must not
	// cause slowdown just because their normals or widths differ.
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	movement_options_floor(&w,&r)
	config:=movement_options_config();config.speed=6;config.acceleration=12;config.braking=4;config.corner_slowdown=true;config.repath_interval=0.1
	agent:=movement_options_agent(&w,&r,{-35,0,2},config)
	assert(ecs.set_navigation_target_3d(&w,agent,{35,0,2}))
	for tick in 0..<540 {
		_,state:=movement_options_tick(&w,agent,1.0/60)
		assert(state.status==.Moving)
		if tick>60 {assert(movement_options_horizontal(state.actual_velocity)>config.speed-0.02,"straight surface crossings retain cruise speed with corner slowdown enabled")}
	}
}

validate_movement_options_controller_corners :: proc() {
	for offset in ([]f32{0,1000}) {
		r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
		w:=ecs.init();defer ecs.destroy(&w)
		vertices:=[][3]f32{{-20,0,0},{4,0,0},{6,0,0},{-20,0,2},{4,0,2},{6,0,2},{4,0,20},{6,0,20}}
		shift:=[3]f32{offset,0,offset}
		for &vertex in vertices {vertex+=shift}
		mesh_entity:=movement_options_mesh(&w,&r,vertices,[][3]i32{{0,1,4},{0,4,3},{1,2,5},{1,5,4},{4,5,7},{4,7,6}})
		floor:=ecs.create_entity(&w)
		floor_pose:=ecs.default_transform();floor_pose.position=shift+[3]f32{0,-0.25,0}
		assert(ecs.add(&w,&r,floor,floor_pose))
		assert(ecs.add(&w,&r,floor,ecs.BoxCollider{size={100,0.5,100},is_static=true,friction=0.6}))
		config:=movement_options_config(true)
		config.speed=6;config.acceleration=12;config.braking=4;config.corner_slowdown=true;config.auto_braking=true
		// Following the two boundary legs creates an exact right angle whose
		// requested corner speed is zero, exercising waypoint advancement.
		agent:=movement_options_agent(&w,&r,shift+[3]f32{-10,0,2},config)
		assert(ecs.set_navigation_target_3d(&w,agent,shift+[3]f32{4,0,12}))
		corner:=shift+[3]f32{4,0,2}
		cruised,slowed,arrived:=false,false,false
		for _ in 0..<1500 {
			pose,state:=movement_options_tick(&w,agent,1.0/60)
			assert(state.status==.Moving || state.status==.Arrived,"native L-corner route remains available")
			speed:=movement_options_horizontal(state.actual_velocity)
			if pose.position.x<offset-4 && speed>config.speed-0.1 {cruised=true}
			if pose.position.x<offset+4 && navigation.distance_3d(pose.position,corner)<3 && speed<config.speed*0.9 {slowed=true}
			mesh,_:=ecs.navigation_mesh_3d(&w,mesh_entity)
			_,_,on_mesh:=navigation.project_point_3d(&mesh,pose.position,0.15)
			assert(on_mesh,"native corner movement stays within controller waypoint tolerance of the corridor")
			if state.status==.Arrived {arrived=true;break}
		}
		assert(cruised && slowed && arrived,"native agents slow for a true L bend and reach the goal at larger world coordinates")
	}
}

validate_movement_options_ramp :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	mesh_entity:=movement_options_mesh(&w,&r,
		[][3]f32{{0,0,0},{4,0,0},{8,2,0},{12,2,0},{0,0,4},{4,0,4},{8,2,4},{12,2,4}},
		[][3]i32{{0,1,5},{0,5,4},{1,2,6},{1,6,5},{2,3,7},{2,7,6}})
	config:=movement_options_config();config.speed=4;config.acceleration=3;config.braking=2
	config.auto_braking=true;config.corner_slowdown=true;config.update_rotation=true;config.angular_speed=90
	start,goal:=[3]f32{1,0,0.7},[3]f32{11,2,3.1}
	agent:=movement_options_agent(&w,&r,start,config)
	assert(ecs.set_navigation_target_3d(&w,agent,goal))
	arrived:=false
	previous:=start
	for _ in 0..<900 {
		pose,state:=movement_options_tick(&w,agent,1.0/60)
		assert(state.status==.Moving || state.status==.Arrived)
		mesh,_:=ecs.navigation_mesh_3d(&w,mesh_entity)
		_,_,on_mesh:=navigation.project_point_3d(&mesh,pose.position,0.002)
		assert(on_mesh,"accelerating and braking Transform motion preserves ramp surface height")
		assert(abs(navigation.area_xz(start,goal,pose.position))<0.002,"turning and corner anticipation do not create ramp detours")
		assert(navigation.distance_3d(previous,pose.position)<=config.speed/60+0.002)
		previous=pose.position
		if state.status==.Arrived {arrived=true;assert(navigation.length_3d(state.actual_velocity)<=0.051);break}
	}
	assert(arrived,"movement options reach and settle on the upper ramp floor")
}

