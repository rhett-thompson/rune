package main

import "core:fmt"
import "rune:assets"
import "rune:ecs"
import "rune:navigation"
import "rune:scene"

// Exercise the actual baked course and its native capsule motor. Synthetic
// Transform-only ramps miss the contact offsets and momentum that cause the
// agent to chase old portals and repeatedly swing its facing on this course.
validate_ramp_facing :: proc() {
	for endpoints in ([][2][3]f32{
		{{-7,0,3},{7,2,3}},
		{{7,2,3},{-7,0,3}},
		{{-1,0.5,0},{7,2,0}},
		{{1,1.5,0},{-7,0,0}},
	}) {
		r:=ecs.init_registry();assert(ecs.register_builtin_components(&r))
		w,loaded:=scene.load("examples/navigation_3d/scenes/main.scene.json",&r)
		assert(loaded,scene.last_load_error())
		m:=assets.Asset_Manager{root="examples/navigation_3d",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
		ecs.sync_navigation_3d(&w,&m)
		agent:=entity(&w,"agent")
		config,_:=ecs.get(&w,agent,ecs.NavAgent3D)
		motor,_:=ecs.get(&w,agent,ecs.CharacterController3D)
		assert(config.drive_controller && config.update_rotation && config.auto_braking && config.corner_slowdown)
		assert(config.angular_speed==360 && motor.acceleration==8 && motor.braking==6,"test uses the example's authored movement options")
		sign:=f32(1) if endpoints[1].x>endpoints[0].x else f32(-1)
		pose,_:=ecs.get_transform(&w,agent)
		pose.position=endpoints[0];pose.rotation.y=90*sign
		assert(ecs.set_transform(&w,agent,pose))
		assert(ecs.set_navigation_target_3d(&w,agent,endpoints[1]))
		previous_yaw:=pose.rotation.y
		ramp_turn:f32
		wrong_way_steps:=0
		arrived:=false
		for _ in 0..<1800 {
			pose,state:=movement_options_tick(&w,agent,1.0/60)
			assert(state.status==.Moving || state.status==.Arrived,"native agents retain a route on both sides of the ramp")
			turn:=abs(movement_options_yaw_delta(previous_yaw,pose.rotation.y))
			assert(turn<=config.angular_speed/60+0.001,"ramp facing still obeys the requested angular speed")
			if pose.position.x> -2.3 && pose.position.x<2.3 {
				ramp_turn+=turn
				if state.desired_velocity.x*sign< -0.05 {wrong_way_steps+=1} else {wrong_way_steps=0}
				assert(wrong_way_steps<6,"ramp steering does not spend repeated frames chasing a waypoint behind the agent")
			}
			assert(pose.rotation.x==0 && pose.rotation.z==0,"ramp movement changes yaw without pitching the agent")
			previous_yaw=pose.rotation.y
			if state.status==.Arrived {
				assert(navigation.distance_3d(pose.position,endpoints[1])<0.3,"ramp facing changes preserve goal arrival")
				arrived=true;break
			}
		}
		assert(arrived,"native course agents reach both floors from the floor and ramp")
		assert(ramp_turn<180,"gentle ramp routes do not repeatedly swing their facing back and forth")
		ecs.destroy(&w);assets.shutdown(&m);ecs.destroy_registry(&r)
	}
	validate_ramp_destination_facing()
	validate_ramp_cruise_speed()
	fmt.println("PASS native example ramp movement: steady cruise, ascent, descent, ramp starts, retargeting and settled facing")
}


// Keep retargeting the same capsule across both floors and a ramp destination.
// Waiting beyond first arrival catches slow contact drift that otherwise starts
// repeatedly requesting a correction and changes facing while stopped.
validate_ramp_destination_facing :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w,loaded:=scene.load("examples/navigation_3d/scenes/main.scene.json",&r)
	assert(loaded,scene.last_load_error());defer ecs.destroy(&w)
	m:=assets.Asset_Manager{root="examples/navigation_3d",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
	defer assets.shutdown(&m)
	ecs.sync_navigation_3d(&w,&m)
	agent:=entity(&w,"agent")
	for goal in ([][3]f32{{7,2,3},{0,1,0},{-7,0,3},{7,2,-3},{-7,0,3}}) {
		assert(ecs.set_navigation_target_3d(&w,agent,goal))
		for _ in 0..<1200 {movement_options_tick(&w,agent,1.0/60)}
		pose,_:=ecs.get_transform(&w,agent)
		state,_:=ecs.get_navigation_state_3d(&w,agent)
		assert(state.status==.Arrived,"floor and ramp destinations stay arrived after braking settles")
		settled_position,settled_yaw:=pose.position,pose.rotation.y
		for _ in 0..<180 {
			pose,state=movement_options_tick(&w,agent,1.0/60)
			assert(state.status==.Arrived,"contact corrections do not restart a settled agent on the ramp")
			assert(abs(movement_options_yaw_delta(settled_yaw,pose.rotation.y))<0.1,"settled ramp agents keep their facing through contact and periodic replans")
			assert(movement_options_horizontal(pose.position-settled_position)<0.025,"settled ramp agents do not creep down the slope")
		}
	}
}


// Measure achieved surface speed on the real course after acceleration has
// settled. Repeatedly flattening and projecting velocity used to reduce a
// requested 3 units/s to about 1.25 units/s in both directions on this ramp.
validate_ramp_cruise_speed :: proc() {
	for endpoints in ([][2][3]f32{{{-1,0.5,0},{7,2,0}},{{1,1.5,0},{-7,0,0}}}) {
		r:=ecs.init_registry();assert(ecs.register_builtin_components(&r))
		w,loaded:=scene.load("examples/navigation_3d/scenes/main.scene.json",&r)
		assert(loaded,scene.last_load_error())
		m:=assets.Asset_Manager{root="examples/navigation_3d",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
		ecs.sync_navigation_3d(&w,&m)
		agent:=entity(&w,"agent")
		config,_:=ecs.get(&w,agent,ecs.NavAgent3D)
		pose,_:=ecs.get_transform(&w,agent)
		sign:=f32(1) if endpoints[1].x>endpoints[0].x else f32(-1)
		pose.position=endpoints[0];pose.rotation.y=90*sign
		assert(ecs.set_transform(&w,agent,pose))
		assert(ecs.set_navigation_target_3d(&w,agent,endpoints[1]))
		cruise_samples:=0
		arrived:=false
		for tick in 0..<1200 {
			pose,state:=movement_options_tick(&w,agent,1.0/60)
			assert(state.status==.Moving || state.status==.Arrived,"native ramp cruise retains its route")
			if tick>=30 && abs(pose.position.x)<1.8 && movement_options_horizontal(state.desired_velocity)>=2.95 {
				assert(abs(navigation.length_3d(state.actual_velocity)-config.speed)<0.06,"native ramp cruise keeps the requested surface speed after acceleration settles")
				assert(abs(movement_options_yaw_delta(90*sign,pose.rotation.y))<0.1,"straight ramp cruise preserves the movement heading")
				cruise_samples+=1
			}
			if state.status==.Arrived {arrived=true;break}
		}
		assert(cruise_samples>=20,"native ramp cruise samples steady speed during both ascent and descent")
		assert(arrived,"native ramp cruise still brakes and reaches its floor destination")
		ecs.destroy(&w);assets.shutdown(&m);ecs.destroy_registry(&r)
	}
}

