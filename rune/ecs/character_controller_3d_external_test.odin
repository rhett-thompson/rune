package ecs

import "core:math"
import "core:testing"

@(test)
character_controller_3d_external_velocity_adds_to_input_and_expires_after_one_step :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	dash_test_box_3d(&w,&r,{0,-0.5,0},{100,1,100})
	idle:=dash_test_actor_3d(&w,&r,{0,0.025,0})
	walking:=dash_test_actor_3d(&w,&r,{0,0.025,5})
	reference:=dash_test_actor_3d(&w,&r,{0,0.025,10})
	assert(character_controller_3d_move(&w,walking,{1,0}))
	assert(character_controller_3d_move(&w,reference,{1,0}))
	for _ in 0..<12 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	idle_start:=w.transforms[idle].position
	walking_start:=w.transforms[walking].position
	reference_start:=w.transforms[reference].position
	assert(character_controller_3d_add_external_velocity(&w,idle,{0.3,0,0}))
	assert(character_controller_3d_add_external_velocity(&w,idle,{0.5,0,0}))
	assert(character_controller_3d_add_external_velocity(&w,walking,{0,0,0.8}))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	idle_delta:=w.transforms[idle].position-idle_start
	walking_delta:=w.transforms[walking].position-walking_start
	reference_delta:=w.transforms[reference].position-reference_start
	testing.expect(t,abs(idle_delta[0]-0.8*Physics3D_Fixed_Delta)<0.0001,
		"external sources accumulate and pull an idle character without input acceleration")
	testing.expect(t,abs(walking_delta[0]-reference_delta[0])<0.0001 && abs(walking_delta[2]-0.8*Physics3D_Fixed_Delta)<0.0001,
		"external motion adds to ordinary walking instead of replacing its heading")
	idle_state:=w.character_controller_states_3d[idle]
	walking_state:=w.character_controller_states_3d[walking]
	testing.expect(t,idle_state.velocity==[3]f32{} && idle_state.pending_external_velocity==[3]f32{} &&
		walking_state.velocity==w.character_controller_states_3d[reference].velocity && walking_state.move==[2]f32{1,0},
		"the request is consumed without changing input or retaining external momentum")
	before:=w.transforms[idle].position
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	testing.expect(t,character_length_3d(w.transforms[idle].position-before)<0.0001,
		"an unrefreshed request cannot move the idle character on another physics step")
}

@(test)
character_controller_3d_external_velocity_sweeps_the_capsule_against_thin_walls :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	dash_test_box_3d(&w,&r,{0,-0.5,0},{100,1,100})
	dash_test_box_3d(&w,&r,{3,2,0},{0.025,4,10})
	e:=dash_test_actor_3d(&w,&r,{0,0.025,0})
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	assert(character_controller_3d_add_external_velocity(&w,e,{2000,0,0}))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	testing.expect(t,w.transforms[e].position[0]>2.5 && w.transforms[e].position[0]<2.65,
		"the complete capsule sweep prevents a fast external contribution tunneling through a thin wall")
	testing.expect(t,w.character_controller_states_3d[e].velocity==[3]f32{} &&
		w.character_controller_states_3d[e].pending_external_velocity==[3]f32{},"a blocked contribution leaves no stored momentum or queued retry")
}

@(test)
character_controller_3d_external_velocity_covers_both_slices_of_a_partial_dash :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	dash_test_box_3d(&w,&r,{0,-0.5,0},{100,1,100})
	e:=dash_test_actor_3d(&w,&r,{0,0.025,0})
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	start:=w.transforms[e].position
	assert(character_controller_3d_dash(&w,e,{1,0,0},15,0.105))
	assert(character_controller_3d_add_external_velocity(&w,e,{0,0,2}))
	character_controllers_3d_step(&w,0.5)
	delta:=w.transforms[e].position-start
	state:=w.character_controller_states_3d[e]
	testing.expect(t,abs(delta[0]-1.575)<0.003 && abs(delta[2]-1)<0.003,
		"external motion spans the full physics step while dash motion spans only its remaining duration")
	testing.expect(t,!state.dashing && state.velocity==[3]f32{} && state.dash_resume_velocity==[3]f32{} &&
		state.pending_external_velocity==[3]f32{},"finishing a dash cannot retain the external contribution")
}

@(test)
character_controller_3d_external_velocity_rejects_invalid_requests_and_resets_with_the_motor :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	e:=dash_test_actor_3d(&w,&r,{0,5,0})
	missing:=create_entity(&w)
	testing.expect(t,!character_controller_3d_add_external_velocity(&w,missing,{1,0,0}),"a complete ready controller is required")
	assert(character_controller_3d_add_external_velocity(&w,e,{0.8,0,0}))
	before:=w.character_controller_states_3d[e]
	for value in ([4]f32{math.nan_f32(),math.inf_f32(1),math.inf_f32(-1),transmute(f32)u32(0x7f7fffff)}) {
		testing.expect(t,!character_controller_3d_add_external_velocity(&w,e,{value,0,0}) &&
			w.character_controller_states_3d[e]==before,"nonfinite input or an overflowing length is rejected without changing a valid pending request")
	}
	assert(character_controller_3d_teleport(&w,e,{0,5,0}))
	large:=f32(1e19)
	assert(character_controller_3d_add_external_velocity(&w,e,{large,0,0}))
	before=w.character_controller_states_3d[e]
	testing.expect(t,!character_controller_3d_add_external_velocity(&w,e,{large,0,0}) &&
		w.character_controller_states_3d[e]==before,"finite components whose accumulated length overflows are rejected atomically")
	assert(character_controller_3d_teleport(&w,e,{0,5,0}))
	testing.expect(t,w.character_controller_states_3d[e].pending_external_velocity==[3]f32{},"teleport clears queued external motion")
	assert(character_controller_3d_add_external_velocity(&w,e,{0.8,0,0}))
	assert(character_controller_3d_set_free_motion(&w,e,true))
	testing.expect(t,w.character_controller_states_3d[e].pending_external_velocity==[3]f32{} &&
		!character_controller_3d_add_external_velocity(&w,e,{0.8,0,0}),"free motion clears and rejects capsule motion requests")
	assert(character_controller_3d_set_free_motion(&w,e,false))
	assert(character_controller_3d_add_external_velocity(&w,e,{0.8,0,0}))
	assert(set_enabled(&w,e,false))
	testing.expect(t,!character_controller_3d_add_external_velocity(&w,e,{0.8,0,0}),"disabled controllers reject requests")
	assert(set_enabled(&w,e,true))
	testing.expect(t,w.character_controller_states_3d[e].pending_external_velocity==[3]f32{},"re-enabling cannot restore a cancelled request")
	assert(character_controller_3d_add_external_velocity(&w,e,{0.8,0,0}))
	assert(remove_component(&w,e,"CharacterController3D"))
	assert(add(&w,&r,e,default_character_controller_3d()))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	testing.expect(t,abs(w.transforms[e].position[0])<0.0001 && w.character_controller_states_3d[e].pending_external_velocity==[3]f32{},
		"removing and re-adding the component cannot revive external motion")
}

@(test)
character_controller_3d_external_velocity_follows_rotated_gravity_walkable_slopes_and_stairs :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	w:=init(); defer destroy(&w)
	dash_test_box_3d(&w,&r,{-0.5,0,0},{1,100,100})
	e:=dash_test_actor_3d(&w,&r,{0.025,0,0})
	assert(character_controller_3d_move_on_plane(&w,e,{},{1,0,0}))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	start:=w.transforms[e].position
	assert(character_controller_3d_add_external_velocity(&w,e,{6,2,0}))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	delta:=w.transforms[e].position-start
	testing.expect(t,abs(delta[1]-2*Physics3D_Fixed_Delta)<0.0001 && abs(delta[0])<0.0001 &&
		w.character_controller_states_3d[e].grounded,"external velocity is projected onto the runtime gravity plane")

	ramp:=init(); defer destroy(&ramp)
	dash_test_box_3d(&ramp,&r,{0,-0.5,0},{100,1,100})
	dash_test_box_3d(&ramp,&r,{5,0.5,0},{8,0.3,3},{0,0,10})
	climber:=dash_test_actor_3d(&ramp,&r,{0,0.025,0})
	physics_3d_update(&ramp,Physics3D_Fixed_Delta)
	for _ in 0..<25 {
		assert(character_controller_3d_add_external_velocity(&ramp,climber,{20,0,0}))
		physics_3d_update(&ramp,Physics3D_Fixed_Delta)
	}
	testing.expect(t,ramp.transforms[climber].position[0]>7 && ramp.transforms[climber].position[1]>0.8 &&
		ramp.character_controller_states_3d[climber].grounded && ramp.character_controller_states_3d[climber].velocity==[3]f32{},
		"refreshed external motion follows a walkable ramp without becoming motor momentum")

	stairs:=init(); defer destroy(&stairs)
	dash_test_box_3d(&stairs,&r,{0,-0.5,0},{100,1,100})
	for i in 0..<5 {dash_test_box_3d(&stairs,&r,{2+f32(i)*0.65,f32(i+1)*0.1,0},{0.65,f32(i+1)*0.2,3})}
	walker:=dash_test_actor_3d(&stairs,&r,{0,0.025,0})
	physics_3d_update(&stairs,Physics3D_Fixed_Delta)
	for _ in 0..<19 {
		assert(character_controller_3d_add_external_velocity(&stairs,walker,{15,0,0}))
		physics_3d_update(&stairs,Physics3D_Fixed_Delta)
	}
	testing.expect(t,stairs.transforms[walker].position[0]>3.5 && stairs.transforms[walker].position[1]>0.7 &&
		stairs.character_controller_states_3d[walker].grounded,"external contributions use the ordinary capsule step solver")
}
