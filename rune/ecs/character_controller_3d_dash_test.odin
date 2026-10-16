package ecs

import "core:math"
import "core:testing"

@(private)
dash_test_actor_3d :: proc(w:^World,r:^Component_Registry,position:[3]f32={})->Entity {
	e:=create_entity(w)
	assert(add(w,r,e,Transform{position=position,scale={1,1,1}}))
	assert(add(w,r,e,default_character_controller_3d()))
	return e
}

@(private)
dash_test_box_3d :: proc(w:^World,r:^Component_Registry,position,size:[3]f32,rotation:[3]f32={})->Entity {
	e:=create_entity(w)
	assert(add(w,r,e,Transform{position=position,rotation=rotation,scale={1,1,1}}))
	assert(add(w,r,e,BoxCollider{size=size,is_static=true}))
	return e
}

@(test)
character_controller_3d_dash_is_finite_and_keeps_its_trigger_heading :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	dash_test_box_3d(&w,&r,{0,-0.5,0},{100,1,100})
	e:=dash_test_actor_3d(&w,&r,{0,0.025,0})
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	for value in ([4]f32{0,-1,math.inf_f32(1),math.nan_f32()}) {
		testing.expect(t,!character_controller_3d_dash(&w,e,{1,0,0},value,0.1))
		testing.expect(t,!character_controller_3d_dash(&w,e,{1,0,0},10,value))
	}
	testing.expect(t,!character_controller_3d_dash(&w,e,{},10,0.1))
	testing.expect(t,!character_controller_3d_dash(&w,e,{0,1,0},10,0.1),"a tangent direction is required")
	testing.expect(t,character_controller_3d_dash(&w,e,{2,8,0},15,0.105))
	testing.expect(t,!character_controller_3d_dash(&w,e,{0,0,1},15,0.105),"an active burst cannot be retriggered")
	start:=w.transforms[e].position
	for _ in 0..<6 {
		assert(character_controller_3d_move(&w,e,{0,1}))
		physics_3d_update(&w,Physics3D_Fixed_Delta)
	}
	testing.expect(t,abs(w.transforms[e].position[0]-start[0]-1.5)<0.002 &&
		abs(w.transforms[e].position[2]-start[2])<0.002,"ordinary steering does not turn an active burst")
	assert(character_controller_3d_move(&w,e,{}))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	state:=w.character_controller_states_3d[e]
	testing.expect(t,!state.dashing && state.dash_remaining==0 && abs(state.velocity[0])<0.001,
		"the last partial tick discards burst momentum")
	testing.expect(t,abs(w.transforms[e].position[0]-start[0]-1.575)<0.003,
		"only the unconsumed five milliseconds run at dash speed")
	before:=w.transforms[e].position[0]
	for _ in 0..<3 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	testing.expect(t,abs(w.transforms[e].position[0]-before)<0.001,"no burst velocity remains after expiry")
}

@(test)
character_controller_3d_dash_bounds_large_steps_and_sweeps_thin_walls :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	dash_test_box_3d(&w,&r,{0,-0.5,0},{100,1,100})
	e:=dash_test_actor_3d(&w,&r,{0,0.025,0})
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	assert(character_controller_3d_dash(&w,e,{1,0,0},15,0.105))
	character_controllers_3d_step(&w,0.5)
	testing.expect(t,abs(w.transforms[e].position[0]-1.575)<0.003 &&
		!w.character_controller_states_3d[e].dashing,"a long motor step cannot stretch burst duration")
	assert(character_controller_3d_teleport(&w,e,{0,0.025,0}))
	dash_test_box_3d(&w,&r,{3,2,0},{0.025,4,10})
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	assert(character_controller_3d_dash(&w,e,{1,0,0},2000,0.1))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	testing.expect(t,w.transforms[e].position[0]>2.5 && w.transforms[e].position[0]<2.65,
		"the complete capsule sweep stops a burst against a thin wall")
}

@(test)
character_controller_3d_dash_preserves_gravity_and_cancellation_resets :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	e:=dash_test_actor_3d(&w,&r,{0,5,0})
	reference:=dash_test_actor_3d(&w,&r,{0,5,3})
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	assert(character_controller_3d_dash(&w,e,{1,0,0},20,0.2))
	for _ in 0..<3 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	testing.expect(t,abs(w.transforms[e].position[1]-w.transforms[reference].position[1])<0.001 &&
		abs(w.character_controller_states_3d[e].velocity[1]-w.character_controller_states_3d[reference].velocity[1])<0.001,
		"airborne dashing preserves falling acceleration")
	assert(character_controller_3d_cancel_dash(&w,e))
	state:=w.character_controller_states_3d[e]
	testing.expect(t,!state.dashing && state.velocity[0]==0 && state.velocity[1]<0,
		"cancellation stops tangent momentum and keeps vertical motion")
	before:=w.transforms[e].position[0]
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	testing.expect(t,abs(w.transforms[e].position[0]-before)<0.001)

	assert(character_controller_3d_dash(&w,e,{1,0,0},20,0.2))
	assert(character_controller_3d_teleport(&w,e,{0,5,0}))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	testing.expect(t,!w.character_controller_states_3d[e].dashing && abs(w.transforms[e].position[0])<0.001,
		"teleport clears a queued or active burst")
	assert(character_controller_3d_dash(&w,e,{1,0,0},20,0.2))
	assert(character_controller_3d_set_free_motion(&w,e,true))
	testing.expect(t,!character_controller_3d_dash(&w,e,{1,0,0},20,0.2),"free motion cannot accept a capsule burst")
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	testing.expect(t,!w.character_controller_states_3d[e].dashing && abs(w.transforms[e].position[0])<0.001,
		"free motion clears the burst")
	assert(character_controller_3d_set_free_motion(&w,e,false))
	assert(character_controller_3d_dash(&w,e,{1,0,0},20,0.2))
	assert(set_enabled(&w,e,false))
	assert(set_enabled(&w,e,true))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	testing.expect(t,!w.character_controller_states_3d[e].dashing && abs(w.transforms[e].position[0])<0.001,
		"disable and re-enable cannot revive a burst")
}

@(test)
character_controller_3d_dash_respects_local_up_and_moving_supports :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	dash_test_box_3d(&w,&r,{-0.5,0,0},{1,100,100})
	e:=dash_test_actor_3d(&w,&r,{0.025,0,0})
	assert(character_controller_3d_move_on_plane(&w,e,{},{1,0,0}))
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	assert(character_controller_3d_dash(&w,e,{6,2,0},10,0.1))
	for _ in 0..<7 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	testing.expect(t,abs(w.transforms[e].position[1]-1)<0.003 && abs(w.transforms[e].position[0])<0.03 &&
		w.character_controller_states_3d[e].grounded,"dash heading and ground contact honor the runtime up frame")

	platform_world:=init(); defer destroy(&platform_world)
	platform:=dash_test_box_3d(&platform_world,&r,{0,-0.5,0},{100,1,100})
	assert(add(&platform_world,&r,platform,RigidBody3D{body_type="kinematic",gravity_scale=0,velocity={2,0,0}}))
	rider:=dash_test_actor_3d(&platform_world,&r,{0,0.025,0})
	for _ in 0..<3 {physics_3d_update(&platform_world,Physics3D_Fixed_Delta)}
	start:=platform_world.transforms[rider].position
	assert(character_controller_3d_dash(&platform_world,rider,{0,0,1},10,0.1))
	for _ in 0..<7 {physics_3d_update(&platform_world,Physics3D_Fixed_Delta)}
	state:=platform_world.character_controller_states_3d[rider]
	delta:=platform_world.transforms[rider].position-start
	testing.expect(t,abs(delta[0]-2*7.0/60)<0.003 && abs(delta[2]-1)<0.003 &&
		state.grounded && state.support_entity==platform,"a dash retains swept moving-platform carry")
}

@(test)
character_controller_3d_dash_uses_walkable_slopes_and_stairs :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	w:=init(); defer destroy(&w)
	dash_test_box_3d(&w,&r,{0,-0.5,0},{100,1,100})
	dash_test_box_3d(&w,&r,{5,0.5,0},{8,0.3,3},{0,0,10})
	e:=dash_test_actor_3d(&w,&r,{0,0.025,0})
	physics_3d_update(&w,Physics3D_Fixed_Delta)
	assert(character_controller_3d_dash(&w,e,{1,0,0},20,0.4))
	for _ in 0..<25 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	testing.expect(t,w.transforms[e].position[0]>7 && w.transforms[e].position[1]>0.8 &&
		w.character_controller_states_3d[e].grounded,"a burst follows a walkable ramp")

	stairs:=init(); defer destroy(&stairs)
	dash_test_box_3d(&stairs,&r,{0,-0.5,0},{100,1,100})
	for i in 0..<5 {dash_test_box_3d(&stairs,&r,{2+f32(i)*0.65,f32(i+1)*0.1,0},{0.65,f32(i+1)*0.2,3})}
	climber:=dash_test_actor_3d(&stairs,&r,{0,0.025,0})
	physics_3d_update(&stairs,Physics3D_Fixed_Delta)
	assert(character_controller_3d_dash(&stairs,climber,{1,0,0},15,0.3))
	for _ in 0..<19 {physics_3d_update(&stairs,Physics3D_Fixed_Delta)}
	testing.expect(t,stairs.transforms[climber].position[0]>3.5 && stairs.transforms[climber].position[1]>0.7 &&
		stairs.character_controller_states_3d[climber].grounded,"a burst uses the ordinary capsule step solver")
}
