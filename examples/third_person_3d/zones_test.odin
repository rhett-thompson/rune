package main

import "core:encoding/json"
import "core:sync"
import "core:testing"
import rune "rune:core"
import "rune:ecs"
import "rune:scene"

expect_zone_event :: proc(t:^testing.T,w:^ecs.World,zone,other:ecs.Entity,kind:ecs.Trigger_Event_Kind_3D) {
	events:=ecs.trigger_events_3d(w)
	if !testing.expect(t,len(events)==1,"one event per zone/entity pair") {return}
	testing.expect(t,events[0].trigger==zone && events[0].other==other && events[0].kind==kind)
}

@(test)
trigger_geometry_and_lifecycle :: proc(t:^testing.T) {
	sync.mutex_lock(&interaction_test_lock);defer sync.mutex_unlock(&interaction_test_lock)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);ecs.register_builtin_components(&r)
	w:=ecs.init();defer ecs.destroy(&w)
	zone:=test_entity(t,&w,&r,{0,1,0})
	actor:=test_entity(t,&w,&r,{1.3,0,1.3})
	ecs.set_entity_metadata(&w,actor,"actor","","",4)
	config:=ecs.Default_Trigger_3D;config.layers=4
	test_add(t,&w,&r,zone,"Trigger3D",config)
	test_add(t,&w,&r,actor,"CharacterController3D",ecs.default_character_controller_3d())
	ecs.update_triggers_3d(&w)
	testing.expect(t,len(ecs.trigger_events_3d(&w))==0,"rounded capsule corner is outside box")
	ecs.character_controller_3d_teleport(&w,actor,{1.2,0,1.2})
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Enter)
	testing.expect(t,ecs.trigger_contains_3d(&w,zone,actor))
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Stay)
	ecs.set_enabled(&w,actor,false)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Exit)
	ecs.update_triggers_3d(&w);testing.expect(t,len(ecs.trigger_events_3d(&w))==0,"exit is emitted once")
	ecs.set_enabled(&w,actor,true)
	config.shape=.sphere;ecs.set(&w,zone,config)
	ecs.character_controller_3d_teleport(&w,actor,{1.36,0,0})
	ecs.update_triggers_3d(&w);testing.expect(t,len(ecs.trigger_events_3d(&w))==0,"sphere reach includes capsule radius exactly")
	ecs.character_controller_3d_teleport(&w,actor,{1.3,0,0})
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Enter)
	config.layers=1;ecs.set(&w,zone,config)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Exit)
	config.layers=4;ecs.set(&w,zone,config)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Enter)
	config.enabled=false;ecs.set(&w,zone,config)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Exit)
	config.enabled=true;ecs.set(&w,zone,config)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Enter)
	ecs.destroy_entity(&w,actor)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Exit)
	testing.expect(t,!ecs.is_alive(&w,actor) && !ecs.trigger_contains_3d(&w,zone,actor),"exit retains identity without a live handle")
	body:=test_entity(t,&w,&r,{0,1,0});ecs.set_entity_metadata(&w,body,"body","","",4)
	test_add(t,&w,&r,body,"BoxCollider",ecs.BoxCollider{size={0.5,0.5,0.5},is_static=true,is_sensor=true})
	ecs.update_triggers_3d(&w);testing.expect(t,len(ecs.trigger_events_3d(&w))==0,"sensors excluded by default")
	config.include_sensors=true;ecs.set(&w,zone,config)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,body,.Enter)
	box,_:=ecs.get_box_collider(&w,body);box.is_sensor=false;ecs.set_box_collider(&w,body,box)
	config.include_sensors=false;ecs.set(&w,zone,config)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,body,.Stay)
	ecs.remove_component(&w,zone,"Trigger3D")
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,body,.Exit)
	test_add(t,&w,&r,zone,"Trigger3D",config)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,body,.Enter)
	ecs.reset_triggers_3d(&w)
	testing.expect(t,len(ecs.trigger_events_3d(&w))==0 && !ecs.trigger_contains_3d(&w,zone,body))
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,body,.Enter)
	config.radius = -1
	testing.expect(t,!ecs.set(&w,zone,config),"typed trigger validation")
	invalid_target:=test_entity(t,&w,&r,{10,10,10})
	for text in ([]string{`{"shape":"cone"}`,`{"size":[1,0,1]}`,`{"radius":-1}`,`{"unexpected":true}`}) {
		value:json.Value;json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)
		_,valid:=ecs.trigger_3d_from_json(value);testing.expect(t,!valid,"invalid trigger JSON rejected")
		testing.expect(t,!ecs.add_component(&w,&r,invalid_target,"Trigger3D",value),"invalid trigger cannot be added to a world")
	}
}

@(test)
trigger_pipeline_and_crouch :: proc(t:^testing.T) {
	sync.mutex_lock(&interaction_test_lock);defer sync.mutex_unlock(&interaction_test_lock)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);ecs.register_builtin_components(&r)
	w:=ecs.init();defer ecs.destroy(&w)
	zone:=test_entity(t,&w,&r,{0,1.6,0})
	actor:=test_entity(t,&w,&r,{})
	config:=ecs.Default_Trigger_3D;config.size={2,0.2,2}
	test_add(t,&w,&r,zone,"Trigger3D",config)
	test_add(t,&w,&r,actor,"CharacterController3D",ecs.default_character_controller_3d())
	engine:=rune.Engine{fixed_delta_time=1.0/60,delta_time=1.0/60}
	rune.run_fixed_pipeline(&engine,&w)
	expect_zone_event(t,&w,zone,actor,.Enter)
	ecs.character_controller_3d_crouch(&w,actor,true)
	rune.run_fixed_pipeline(&engine,&w)
	expect_zone_event(t,&w,zone,actor,.Exit)
	// A parent translates and scales the trigger; rotation intentionally does
	// not rotate its world-axis-aligned box.
	parent:=test_entity(t,&w,&r,{4,0,0})
	p,_:=ecs.get_transform(&w,parent);p.scale={2,2,2};p.rotation={0,45,0};ecs.set_transform(&w,parent,p)
	ecs.set_parent(&w,zone,parent)
	p,_=ecs.get_transform(&w,zone);p.position={0,1,0};ecs.set_transform(&w,zone,p)
	config.size={2,2,2};ecs.set(&w,zone,config)
	ecs.character_controller_3d_teleport(&w,actor,{5.5,0,0})
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Enter)
	ecs.set_enabled(&w,parent,false)
	ecs.update_triggers_3d(&w);expect_zone_event(t,&w,zone,actor,.Exit)
}

@(test)
course_checkpoint_and_hazard :: proc(t:^testing.T) {
	sync.mutex_lock(&interaction_test_lock);defer sync.mutex_unlock(&interaction_test_lock)
	reset_interactions();defer reset_interactions()
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);ecs.register_builtin_components(&r);register_course_components(&r)
	layers:=make(map[string]u8);defer delete(layers);layers["Gameplay"]=1;layers["Player"]=2
	w,ok:=scene.load_with_layers("examples/third_person_3d/scenes/main.scene.json",&r,layers)
	defer scene.clear_load_error();if !testing.expect(t,ok,scene.last_load_error()) {return};defer ecs.destroy(&w)
	a,_:=ecs.find_entity_by_id(&w,"player")
	pickup,_:=ecs.find_entity_by_id(&w,"interaction_pickup")
	activate_course_interaction(&w,pickup)
	ecs.character_controller_3d_teleport(&w,a,{5,0,8})
	ecs.update_triggers_3d(&w)
	testing.expect(t,!process_course_zones(&w),"hazard initially hurts rather than instantly respawning")
	health,_:=ecs.get(&w,a,Health)
	testing.expect(t,health.current==75)
	for _ in 0..<3 {
		update_course_health(&w,Default_Health.hit_protection)
		ecs.update_triggers_3d(&w);process_course_zones(&w)
	}
	testing.expect(t,actor_dead(&w,a),"remaining in hazard causes repeated damage and death")
	testing.expect(t,update_course_health(&w,Default_Health.respawn_delay),"death countdown respawns player")
	pose,_:=ecs.get_transform(&w,a)
	testing.expect(t,pose.position==Default_Respawn_Point.position,"hazard before checkpoint returns to start")
	ecs.character_controller_3d_teleport(&w,a,{-5,0,8})
	ecs.update_triggers_3d(&w)
	testing.expect(t,!process_course_zones(&w))
	respawn,_:=ecs.get(&w,a,Respawn_Point)
	testing.expect(t,respawn.checkpoint.id=="checkpoint_zone" && respawn.position==([3]f32{-5,0.05,8}),"checkpoint activates")
	ecs.character_controller_3d_teleport(&w,a,{5,0,8})
	ecs.character_controller_3d_jump(&w,a)
	update_course_health(&w,Default_Health.respawn_protection)
	for hit in 0..<4 {
		if hit>0 {update_course_health(&w,Default_Health.hit_protection)}
		ecs.update_triggers_3d(&w);process_course_zones(&w)
	}
	testing.expect(t,update_course_health(&w,Default_Health.respawn_delay))
	pose,_=ecs.get_transform(&w,a);state,_:=ecs.get_character_controller_3d_state(&w,a)
	testing.expect(t,pose.position==respawn.position && !state.active && !state.jump_requested && state.velocity==([3]f32{}),"respawn clears motor momentum and buffered jump")
	testing.expect(t,inventory_count(&w,a,"brass_key")==1 && !ecs.is_enabled(&w,pickup),"hazard retains inventory and collected pickup")
	ecs.update_triggers_3d(&w)
	testing.expect(t,!process_course_zones(&w),"safe spawn does not loop through hazard")
}
