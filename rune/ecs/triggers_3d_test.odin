package ecs

import "core:testing"

@(test)
trigger_center_follows_scaled_rotated_ancestors :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r)
	testing.expect(t,register_builtin_components(&r))
	parent:=create_entity(&w)
	testing.expect(t,add(&w,&r,parent,Transform{position={10,0,10},rotation={0,90,0},scale={2,3,4}}))
	gap:=create_entity(&w); testing.expect(t,set_parent(&w,gap,parent))
	zone:=create_entity(&w); testing.expect(t,set_parent(&w,zone,gap))
	testing.expect(t,add(&w,&r,zone,Transform{position={1,1,0},scale={0.5,1,0.25}}))
	value:=Default_Trigger_3D; value.offset={0,0.5,0}
	testing.expect(t,add(&w,&r,zone,value))
	center,half_size,radius,valid:=trigger_geometry_3d(&w,zone,value)
	testing.expect(t,valid)
	expected:=[3]f32{10,3.5,8}
	for axis in 0..<3 {testing.expect(t,abs(center[axis]-expected[axis])<0.001)}
	testing.expect(t,half_size==([3]f32{1,3,1}) && radius==3,
		"dimensions retain hierarchy scale and offset remains world-axis aligned")
	actor:=create_entity(&w)
	testing.expect(t,add(&w,&r,actor,Transform{position={10,3,8},scale={1,1,1}}))
	testing.expect(t,add(&w,&r,actor,default_character_controller_3d()))
	update_triggers_3d(&w)
	testing.expect(t,trigger_contains_3d(&w,zone,actor),"a root-space capsule enters the visible zone")
	// Movement and reparenting affect detection without editing the local zone.
	pose,_:=get_transform(&w,parent); pose.position.y+=5
	testing.expect(t,set_transform(&w,parent,pose))
	center,_,_,valid=trigger_geometry_3d(&w,zone,value)
	testing.expect(t,valid && abs(center.y-8.5)<0.001)
	update_triggers_3d(&w)
	testing.expect(t,!trigger_contains_3d(&w,zone,actor) && len(trigger_events_3d(&w))==1 && trigger_events_3d(&w)[0].kind==.Exit,
		"moving the parent away emits an exit at the previous world location")
	testing.expect(t,set_parent(&w,zone,0))
	center,half_size,radius,valid=trigger_geometry_3d(&w,zone,value)
	testing.expect(t,valid && center==([3]f32{1,1.5,0}) && half_size==([3]f32{0.5,1,0.25}) && radius==1)
}

@(test)
trigger_character_tree_matches_exhaustive_detection_across_pose_and_activation_changes :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	actors:[96]Entity
	for &actor,i in actors {
		actor=create_entity(&w)
		pose:=default_transform();pose.position={f32(i%12)*2-12,f32(i%3)-1,f32(i/12)*2-8}
		assert(add(&w,&r,actor,pose) && add(&w,&r,actor,default_character_controller_3d()))
		state:=Character_Controller_State_3D{active=true,height=1.0 if i%3==0 else 1.8}
		if i%4==0 {state.up={0.70710677,0.70710677,0}}
		if i%7==0 {state.up={-1,0,0}}
		w.character_controller_states_3d[actor]=state
		assert(set_entity_layer_mask(&w,actor,1 if i%2==0 else 2))
	}
	zones:[8]Entity
	for &zone,i in zones {
		zone=create_entity(&w)
		pose:=default_transform();pose.position={f32(i%4)*5-10,0,f32(i/4)*8-7}
		value:=Default_Trigger_3D;value.size={6,4,5};value.radius=4
		if i%2==1 {value.shape=.sphere}
		value.layers=1 if i%3==0 else 3
		assert(add(&w,&r,zone,pose) && add(&w,&r,zone,value))
	}
	previous:=make(map[Trigger_Pair_3D]bool);defer delete(previous)
	for round in 0..<4 {
		if round==1 {
			assert(set_enabled(&w,actors[5],false))
			pose,_:=get_transform(&w,actors[12]);pose.position={10000,10000,10000};assert(set_transform(&w,actors[12],pose))
			assert(set_enabled(&w,zones[2],false))
		}
		if round==2 {
			assert(set_enabled(&w,actors[5],true) && set_enabled(&w,zones[2],true))
			pose,_:=get_transform(&w,actors[12]);pose.position={0,0,0};assert(set_transform(&w,actors[12],pose))
			// A long tilted capsule extends well beyond its feet into a zone.
			config,_:=get_character_controller_3d(&w,actors[12]);config.height=30;assert(set_character_controller_3d(&w,actors[12],config))
			w.character_controller_states_3d[actors[12]]={up={-1,0,0}}
		}
		if round==3 {for zone in zones {assert(remove_component(&w,zone,"Trigger3D"))}}
		expected:=make(map[Trigger_Pair_3D]bool);defer delete(expected)
		for zone in zones {
			value,found:=get(&w,zone,Trigger3D)
			if !found || !value.enabled || !is_enabled(&w,zone) {continue}
			center,half,radius,valid:=trigger_geometry_3d(&w,zone,value);assert(valid)
			for actor in actors {
				layers,_:=entity_layer_mask(&w,actor)
				if layers&value.layers!=0 && trigger_overlaps_character_3d(&w,actor,value,center,half,radius) {expected[{zone,actor}]=true}
			}
		}
		update_triggers_3d(&w)
		testing.expect(t,len(w.triggers_3d.overlaps)==len(expected))
		for pair in expected {testing.expect(t,trigger_contains_3d(&w,pair.trigger,pair.other),"spatial pruning must retain every exact capsule hit")}
		event_count:=len(expected)
		for pair in previous {if !expected[pair] {event_count+=1}}
		testing.expect(t,len(trigger_events_3d(&w))==event_count)
		for event in trigger_events_3d(&w) {
			pair:=Trigger_Pair_3D{event.trigger,event.other}
			kind:=Trigger_Event_Kind_3D.Exit
			if expected[pair] {kind=.Stay if previous[pair] else .Enter}
			testing.expect(t,event.kind==kind,"enter/stay/exit semantics match exhaustive sampling")
		}
		clear(&previous);for pair in expected {previous[pair]=true}
	}
}
