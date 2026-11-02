package ecs

import "core:math"
import "core:testing"

@(test)
character_controller_3d_focused_step_moves_only_the_selected_capsule :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r);assert(register_builtin_components(&r))
	dash_test_box_3d(&w,&r,{0,-.5,0},{20,1,20})
	actor:=dash_test_actor_3d(&w,&r,{0,.025,0})
	other:=dash_test_actor_3d(&w,&r,{0,.025,3})
	rigid:=dash_test_box_3d(&w,&r,{-4,1,0},{.5,.5,.5})
	assert(add(&w,&r,rigid,RigidBody3D{body_type="dynamic",gravity_scale=0,velocity={1,0,0}}))
	assert(character_controller_3d_move(&w,actor,{1,0}) && character_controller_3d_move(&w,other,{1,0}))
	other_before:=w.transforms[other]
	rigid_before:=w.transforms[rigid]
	accumulator:=w.physics_3d_accumulator
	for _ in 0..<60 {assert(character_controller_3d_step(&w,actor,Physics3D_Fixed_Delta))}
	testing.expect(t,w.transforms[actor].position[0]>3 && w.character_controller_states_3d[actor].grounded,"The selected capsule walks and grounds through the real native solver")
	testing.expect(t,w.transforms[other]==other_before && !w.character_controller_states_3d[other].active,"The other controller keeps its position and unconsumed movement request")
	testing.expect(t,w.transforms[rigid]==rigid_before && w.physics_3d_accumulator==accumulator,"Focused motion does not advance rigid bodies or the world's fixed-step clock")
}

@(test)
character_controller_3d_focused_step_syncs_moved_shapes_and_retains_capsule_collision :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r);assert(register_builtin_components(&r))
	floor:=dash_test_box_3d(&w,&r,{0,-.5,0},{12,1,12})
	wall:=dash_test_box_3d(&w,&r,{5,1.5,0},{.1,3,12})
	actor:=dash_test_actor_3d(&w,&r,{0,.025,0})
	for _ in 0..<12 {assert(character_controller_3d_step(&w,actor,Physics3D_Fixed_Delta))}
	pose:=w.transforms[wall];pose.position[0]=1;assert(set_transform(&w,wall,pose))
	assert(character_controller_3d_move(&w,actor,{1,0}))
	for _ in 0..<60 {assert(character_controller_3d_step(&w,actor,Physics3D_Fixed_Delta))}
	state:=w.character_controller_states_3d[actor]
	testing.expect(t,w.transforms[actor].position[0]>.5 && w.transforms[actor].position[0]<.7 && state.support_entity==floor,"Current collider transforms block the swept capsule while the native world remains paused")
	// Moving a support is also visible without a native World_Step.
	pose=w.transforms[floor];pose.position[2]=.4;assert(set_transform(&w,floor,pose))
	assert(character_controller_3d_move(&w,actor,{}))
	before:=w.transforms[actor].position
	assert(character_controller_3d_step(&w,actor,Physics3D_Fixed_Delta))
	testing.expect(t,abs(w.transforms[actor].position[2]-before[2]-.4)<.001,"The ordinary moving-support contact carries the focused capsule")
	before=w.transforms[actor].position
	for invalid in ([4]f32{0,-1,math.nan_f32(),math.inf_f32(1)}) {
		testing.expect(t,!character_controller_3d_step(&w,actor,invalid) && w.transforms[actor].position==before,"Invalid elapsed time cannot alter the actor or native state")
	}
	testing.expect(t,!character_controller_3d_step(nil,actor,Physics3D_Fixed_Delta) && !character_controller_3d_step(&w,0,Physics3D_Fixed_Delta))
}
