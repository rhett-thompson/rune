package ecs

import "core:testing"

@(test)
interaction_handles_scenes_without_targets_and_later_target_removal :: proc(t: ^testing.T) {
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r)
	testing.expect(t,register_builtin_components(&r))
	actor:=create_entity(&w)
	testing.expect(t,add(&w,&r,actor,default_transform()))
	testing.expect(t,add(&w,&r,actor,Default_Interactor_3D))
	origin,forward:=[3]f32{0,1,0},[3]f32{0,0,1}
	_,has_targets:=w.typed_component_data["Interactable3D"]
	testing.expect(t,!has_targets,"a scene with only an actor has no target component bucket")
	testing.expect(t,find_interaction_3d(&w,actor,origin,forward).entity==0)
	state:Interaction_State_3D
	testing.expect(t,update_interaction_3d(&w,&state,actor,origin,forward,false,1.0/60)==0)
	testing.expect(t,update_interaction_3d(&w,&state,actor,origin,forward,true,1.0/60)==0)
	testing.expect(t,state.focus.entity==0 && !state.holding && state.progress==0)
	button:=create_entity(&w)
	testing.expect(t,add(&w,&r,button,Transform{position={0,1,2},scale={1,1,1}}))
	testing.expect(t,add(&w,&r,button,Default_Interactable_3D))
	testing.expect(t,find_interaction_3d(&w,actor,origin,forward).entity==button)
	update_interaction_3d(&w,&state,actor,origin,forward,false,1.0/60)
	testing.expect(t,update_interaction_3d(&w,&state,actor,origin,forward,true,1.0/60)==button)
	destroy_entity(&w,button)
	testing.expect(t,find_interaction_3d(&w,actor,origin,forward).entity==0)
	testing.expect(t,update_interaction_3d(&w,&state,actor,origin,forward,true,1.0/60)==0)
	testing.expect(t,state.focus.entity==0 && !state.holding && state.progress==0,"removing the last target clears interaction state")
}

@(test)
interaction_follows_scaled_rotated_ancestors_and_moving_parent :: proc(t: ^testing.T) {
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r)
	testing.expect(t,register_builtin_components(&r))
	actor:=create_entity(&w)
	testing.expect(t,add(&w,&r,actor,default_transform()))
	testing.expect(t,add(&w,&r,actor,Interactor3D{range=4,half_angle=10,target_layers=~u64(0),require_line_of_sight=false}))
	parent:=create_entity(&w)
	testing.expect(t,add(&w,&r,parent,Transform{position={10,0,10},rotation={0,90,0},scale={2,3,4}}))
	gap:=create_entity(&w); testing.expect(t,set_parent(&w,gap,parent))
	button:=create_entity(&w); testing.expect(t,set_parent(&w,button,gap))
	testing.expect(t,add(&w,&r,button,Transform{position={1,1,0},scale={0.5,1,0.25}}))
	testing.expect(t,add(&w,&r,button,Interactable3D{prompt="Use control",offset={0,0.5,0},hold_seconds=0.2,enabled=true}))
	// A 90-degree yaw maps the scaled local X offset to negative world Z.
	// The interaction offset retains its documented world-axis meter units.
	origin:=[3]f32{10,3.5,5}; forward:=[3]f32{0,0,1}
	focus:=find_interaction_3d(&w,actor,origin,forward)
	testing.expect(t,focus.entity==button)
	expected:=[3]f32{10,3.5,8}
	for axis in 0..<3 {testing.expect(t,abs(focus.point[axis]-expected[axis])<0.001)}
	testing.expect(t,abs(focus.distance-3)<0.001)
	state:Interaction_State_3D
	testing.expect(t,update_interaction_3d(&w,&state,actor,origin,forward,true,0.1)==0 && abs(state.progress-0.5)<0.001)
	testing.expect(t,update_interaction_3d(&w,&state,actor,origin,forward,true,0.1)==button)
	testing.expect(t,update_interaction_3d(&w,&state,actor,origin,forward,true,0.1)==0,"a completed hold activates only once")
	// Moving the parent updates targeting without rewriting the child's pose.
	pose,_:=get_transform(&w,parent); pose.position[1]+=5; set_transform(&w,parent,pose)
	focus=find_interaction_3d(&w,actor,origin+[3]f32{0,5,0},forward)
	testing.expect(t,focus.entity==button && abs(focus.point[1]-8.5)<0.001)
	testing.expect(t,find_interaction_3d(&w,actor,origin,forward).entity==0,"the old control location is no longer reachable")
}
