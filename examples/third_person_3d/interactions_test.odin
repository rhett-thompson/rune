package main

import "core:encoding/json"
import "core:os"
import "core:sync"
import "core:testing"
import "rune:assets"
import "rune:ecs"
import "rune:scene"

interaction_test_lock:sync.Mutex
test_add :: proc(t:^testing.T,w:^ecs.World,r:^ecs.Component_Registry,e:ecs.Entity,name:string,value:$T) {
	data,ok:=ecs.runtime_json(value)
	testing.expect(t,ok && ecs.add_component(w,r,e,name,data),name)
}
test_entity :: proc(t:^testing.T,w:^ecs.World,r:^ecs.Component_Registry,p:[3]f32) -> ecs.Entity {
	e:=ecs.create_entity(w)
	test_add(t,w,r,e,"Transform",ecs.Transform{position=p,scale={1,1,1}})
	return e
}

@(test)
interaction_selection_and_input :: proc(t:^testing.T) {
	sync.mutex_lock(&interaction_test_lock);defer sync.mutex_unlock(&interaction_test_lock)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	a:=test_entity(t,&w,&r,{0,1,0})
	b:=test_entity(t,&w,&r,{0,1,2})
	c:=test_entity(t,&w,&r,{0.5,1,1.5})
	test_add(t,&w,&r,a,"Interactor3D",ecs.Default_Interactor_3D)
	test_add(t,&w,&r,b,"Interactable3D",ecs.Default_Interactable_3D)
	test_add(t,&w,&r,c,"Interactable3D",ecs.Default_Interactable_3D)
	origin:=[3]f32{0,1,0};forward:=[3]f32{0,0,1}
	testing.expect(t,ecs.find_interaction_3d(&w,a,origin,forward).entity==b,"centered target beats closer off-axis target")
	testing.expect(t,ecs.find_interaction_3d(&w,a,origin,-forward).entity==0,"facing cone")
	testing.expect(t,ecs.find_interaction_3d(&w,a,{0,10,0},forward).entity==0,"full XYZ reach")
	testing.expect(t,ecs.find_interaction_3d(&w,a,origin,{}).entity==0,"zero direction rejected")
	ecs.set_enabled(&w,c,false)
	wall:=test_entity(t,&w,&r,{0,1,1})
	test_add(t,&w,&r,wall,"BoxCollider",ecs.BoxCollider{size={2,2,0.2},is_static=true})
	testing.expect(t,ecs.find_interaction_3d(&w,a,origin,forward).entity==0,"wall blocks target")
	box,_:=ecs.get_box_collider(&w,wall);box.is_sensor=true;ecs.set_box_collider(&w,wall,box)
	testing.expect(t,ecs.find_interaction_3d(&w,a,origin,forward).entity==b,"sensor does not obstruct")
	ecs.set_enabled(&w,wall,false)
	test_add(t,&w,&r,b,"BoxCollider",ecs.BoxCollider{size={0.5,1,0.5},is_static=true})
	testing.expect(t,ecs.find_interaction_3d(&w,a,origin,forward).entity==b,"target's own collider is visible")
	state:ecs.Interaction_State_3D
	testing.expect(t,ecs.update_interaction_3d(&w,&state,a,origin,forward,true,0.1)==b,"press fires")
	testing.expect(t,ecs.update_interaction_3d(&w,&state,a,origin,forward,true,0.1)==0,"held button never repeats")
	ecs.update_interaction_3d(&w,&state,a,origin,forward,false,0.1)
	value:=ecs.Default_Interactable_3D;value.hold_seconds=1;ecs.set(&w,b,value)
	testing.expect(t,ecs.update_interaction_3d(&w,&state,a,origin,forward,true,0.4)==0 && state.progress==0.4,"hold starts")
	ecs.update_interaction_3d(&w,&state,a,origin,forward,false,0.1)
	testing.expect(t,state.progress==0,"release cancels progress")
	ecs.update_interaction_3d(&w,&state,a,origin,forward,true,0.4)
	ecs.set_enabled(&w,wall,true);box.is_sensor=false;ecs.set_box_collider(&w,wall,box)
	ecs.update_interaction_3d(&w,&state,a,origin,forward,true,1)
	testing.expect(t,state.focus.entity==0 && state.progress==0,"obstruction cancels hold")
	ecs.set_enabled(&w,wall,false)
	testing.expect(t,ecs.update_interaction_3d(&w,&state,a,origin,forward,true,2)==0,"regaining focus requires release")
	ecs.update_interaction_3d(&w,&state,a,origin,forward,false,0)
	ecs.update_interaction_3d(&w,&state,a,origin,forward,true,0.5)
	testing.expect(t,ecs.update_interaction_3d(&w,&state,a,origin,forward,true,0.5)==b,"hold completes once")
	testing.expect(t,ecs.update_interaction_3d(&w,&state,a,origin,forward,true,2)==0,"completed hold never repeats")
	ecs.update_interaction_3d(&w,&state,a,origin,forward,false,0)
	ecs.update_interaction_3d(&w,&state,a,origin,forward,true,0.5)
	value.prompt="New action";ecs.set(&w,b,value)
	testing.expect(t,ecs.update_interaction_3d(&w,&state,a,origin,forward,true,1)==0 && state.progress==0,"editing action cancels hold")
	value.hold_seconds = -1
	testing.expect(t,!ecs.set(&w,b,value),"typed invalid settings rejected")
	bad:json.Value
	bad_text:=`{"range":0}`
	json.unmarshal(transmute([]u8)bad_text,&bad,allocator=context.temp_allocator)
	_,valid:=ecs.interaction_component_3d_from_json(bad,ecs.Interactor3D)
	testing.expect(t,!valid,"JSON invalid settings rejected")
	actor_config:=ecs.Default_Interactor_3D;actor_config.target_layers=0;ecs.set(&w,a,actor_config)
	testing.expect(t,ecs.find_interaction_3d(&w,a,origin,forward).entity==0,"target layer mask")
	ecs.set(&w,a,ecs.Default_Interactor_3D)
	ecs.destroy_entity(&w,b)
	ecs.update_interaction_3d(&w,&state,a,origin,forward,true,1)
	testing.expect(t,state.focus.entity==0,"destroyed target cancels safely")
}

@(test)
course_interaction_effects :: proc(t:^testing.T) {
	sync.mutex_lock(&interaction_test_lock);defer sync.mutex_unlock(&interaction_test_lock)
	reset_interactions();defer reset_interactions()
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	ecs.register_builtin_components(&r)
	testing.expect(t,register_course_components(&r))
	layers:=make(map[string]u8);defer delete(layers)
	layers["Gameplay"]=1;layers["Player"]=2
	w,ok:=scene.load_with_layers("examples/third_person_3d/scenes/main.scene.json",&r,layers)
	defer scene.clear_load_error()
	if !testing.expect(t,ok,scene.last_load_error()) {return};defer ecs.destroy(&w)
	a,_:=ecs.find_entity_by_id(&w,"player")
	door,_:=ecs.find_entity_by_id(&w,"interaction_door")
	testing.expect(t,activate_course_interaction(&w,door)=="Requires a brass key. Find it beside the guide.","locked door rejects use")
	locked,_:=ecs.get(&w,door,Door_State)
	testing.expect(t,!locked.unlocked && !locked.open)
	pickup,_:=ecs.find_entity_by_id(&w,"interaction_pickup")
	activate_course_interaction(&w,pickup)
	testing.expect(t,inventory_count(&w,a,"brass_key")==1,"pickup enters inventory")
	activate_course_interaction(&w,pickup)
	testing.expect(t,inventory_count(&w,a,"brass_key")==1,"collected pickup cannot duplicate items")
	pose,_:=ecs.get_transform(&w,a);pose.position={0,0,8.5};ecs.set_transform(&w,a,pose)
	testing.expect(t,ecs.find_interaction_3d(&w,a,{0,1.2,8.5},{0,0,-1}).entity==door,"closed door can be selected")
	testing.expect(t,activate_course_interaction(&w,door)=="Door opening.")
	door_pose,_:=ecs.get_transform(&w,door)
	testing.expect(t,door_pose.position.y==Door_Closed_Y,"activation does not teleport the door")
	update_course_door(&w,Door_Travel_Time*0.5)
	door_pose,_=ecs.get_transform(&w,door)
	testing.expect(t,door_pose.position.y>Door_Closed_Y && door_pose.position.y<Door_Open_Y,"door travels through intermediate positions")
	moving_hit,moving_blocked:=ecs.physics_3d_raycast(&w,{0,3,8.5},{0,0,-3},{layers=~u64(0),ignore=a})
	testing.expect(t,moving_blocked && moving_hit.entity==door,"collision follows the animated panel")
	// Reversing starts from the current height without a snap.
	testing.expect(t,activate_course_interaction(&w,door)=="Door closing.")
	update_course_door(&w,0.05)
	reversed_pose,_:=ecs.get_transform(&w,door)
	testing.expect(t,reversed_pose.position.y<door_pose.position.y && reversed_pose.position.y>Door_Closed_Y,"mid-travel reversal")
	activate_course_interaction(&w,door)
	// Rebuilding transient state (as on scene reload) preserves the destination.
	door_animation={}
	for _ in 0..<60 {update_course_door(&w,1.0/60)}
	door_pose,_=ecs.get_transform(&w,door)
	testing.expect(t,door_pose.position.y==Door_Open_Y,"animation reaches exact endpoint after reset")
	hit,blocked:=ecs.physics_3d_raycast(&w,{0,1,8.5},{0,0,-3},{layers=~u64(0),ignore=a})
	testing.expect(t,!blocked || hit.entity!=door,"opening clears collision")
	testing.expect(t,ecs.find_interaction_3d(&w,a,{0,1.2,8.5},{0,0,-1}).entity==door,"open door retains reachable switch")
	pose.position={0,0,6.5};ecs.set_transform(&w,a,pose)
	testing.expect(t,activate_course_interaction(&w,door)=="The doorway is blocked.","cannot close on a character")
	pose.position={0,0,8.5};ecs.set_transform(&w,a,pose)
	testing.expect(t,activate_course_interaction(&w,door)=="Door closing.")
	update_course_door(&w,0.1)
	pose.position={0,0,6.5};ecs.set_transform(&w,a,pose)
	update_course_door(&w,0.1)
	value,_:=ecs.get(&w,door,ecs.Interactable3D)
	testing.expect(t,value.prompt=="Close door","entering the doorway during closing reopens it")
	for _ in 0..<60 {update_course_door(&w,1.0/60)}
	door_pose,_=ecs.get_transform(&w,door)
	testing.expect(t,door_pose.position.y==Door_Open_Y,"blocked door returns fully open")
	pose.position={0,0,8.5};ecs.set_transform(&w,a,pose)
	activate_course_interaction(&w,door)
	for _ in 0..<60 {update_course_door(&w,1.0/60)}
	door_pose,_=ecs.get_transform(&w,door)
	testing.expect(t,door_pose.position.y==Door_Closed_Y,"closing reaches exact endpoint")
	hit,blocked=ecs.physics_3d_raycast(&w,{0,1,8.5},{0,0,-3},{layers=~u64(0),ignore=a})
	testing.expect(t,blocked && hit.entity==door,"closing restores collision")
	testing.expect(t,!ecs.is_enabled(&w,pickup),"pickup disappears")
	guide,_:=ecs.find_entity_by_id(&w,"interaction_guide")
	testing.expect(t,activate_course_interaction(&w,guide)!="","guide dialogue")
}

@(test)
terrain_obstructs_interactions :: proc(t:^testing.T) {
	sync.mutex_lock(&interaction_test_lock);defer sync.mutex_unlock(&interaction_test_lock)
	bytes:[17*17*2]u8
	for z in 0..<17 {bytes[(z*17+8)*2]=255;bytes[(z*17+8)*2+1]=255}
	testing.expect(t,os.write_entire_file("build/interaction-ridge.r16",bytes[:])==nil)
	defer os.remove("build/interaction-ridge.r16")
	descriptor:=`{"heightmap":"build/interaction-ridge.r16","resolution":[17,17],"size":[16,16],"height_scale":4,"chunk_cells":8}`
	testing.expect(t,os.write_entire_file("build/interaction-ridge.terrain.json",transmute([]u8)descriptor)==nil)
	defer os.remove("build/interaction-ridge.terrain.json")
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);ecs.register_builtin_components(&r)
	w:=ecs.init();defer ecs.destroy(&w)
	m:=assets.Asset_Manager{root=".",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
	defer assets.shutdown(&m)
	a:=test_entity(t,&w,&r,{2,1,8});b:=test_entity(t,&w,&r,{14,1,8});ground:=test_entity(t,&w,&r,{})
	actor_config:=ecs.Default_Interactor_3D;actor_config.range=20
	test_add(t,&w,&r,a,"Interactor3D",actor_config)
	test_add(t,&w,&r,b,"Interactable3D",ecs.Default_Interactable_3D)
	terrain_config:=ecs.default_terrain();terrain_config.asset="build/interaction-ridge.terrain.json"
	test_add(t,&w,&r,ground,"Terrain",terrain_config);ecs.sync_terrains(&w,&m)
	testing.expect(t,ecs.find_interaction_3d(&w,a,{2,1,8},{1,0,0}).entity==0,"terrain ridge blocks interaction")
	ecs.set_enabled(&w,ground,false)
	testing.expect(t,ecs.find_interaction_3d(&w,a,{2,1,8},{1,0,0}).entity==b,"disabling terrain restores visibility")
}
