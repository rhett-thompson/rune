package ecs

import "core:testing"

character_support_momentum_test_box :: proc(w:^World,r:^Component_Registry,position,size:[3]f32,velocity:[3]f32={},enclosed:bool=false)->Entity {
	entity:=create_entity(w)
	assert(add(w,r,entity,Transform{position=position,scale={1,1,1}}))
	parts:=[4]BoxCollider_Box{
		{offset={-size[0]*0.5+0.1,2.75,0},size={0.2,5,size[2]}},
		{offset={ size[0]*0.5-0.1,2.75,0},size={0.2,5,size[2]}},
		{offset={0,2.75,-size[2]*0.5+0.1},size={size[0],5,0.2}},
		{offset={0,2.75, size[2]*0.5-0.1},size={size[0],5,0.2}},
	}
	collider:=BoxCollider{size=size}
	if enclosed {collider.additional_boxes=parts[:]}
	assert(add(w,r,entity,collider))
	assert(add(w,r,entity,RigidBody3D{body_type="kinematic",gravity_scale=0,velocity=velocity}))
	return entity
}

character_support_momentum_test_actor :: proc(w:^World,r:^Component_Registry,position:[3]f32)->Entity {
	entity:=create_entity(w)
	assert(add(w,r,entity,Transform{position=position,scale={1,1,1}}))
	assert(add(w,r,entity,default_character_controller_3d()))
	return entity
}

@(test)
character_controller_3d_fast_support_jump_preserves_cabin_relative_position_through_landing :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	for direction in ([4][3]f32{{1,0,0},{-1,0,0},{0,0,1},{0,0,-1}}) {
		w:=init(); defer destroy(&w)
		r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
		carrier:=character_support_momentum_test_box(&w,&r,{0,-0.25,0},{12,0.5,12},{},true)
		actor:=character_support_momentum_test_actor(&w,&r,{0,0.025,0})
		for _ in 0..<12 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
		body,_:=get(&w,carrier,RigidBody3D); body.velocity=direction*12; assert(set(&w,carrier,body))
		for _ in 0..<12 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
		platform,_:=get_transform(&w,carrier); feet,_:=get_transform(&w,actor)
		start:=feet.position-platform.position
		state,_:=get_character_controller_3d_state(&w,actor)
		if !testing.expect(t,state.grounded && state.support_entity==carrier) {continue}
		assert(character_controller_3d_jump(&w,actor))
		physics_3d_update(&w,Physics3D_Fixed_Delta)
		state,_=get_character_controller_3d_state(&w,actor)
		platform,_=get_transform(&w,carrier); feet,_=get_transform(&w,actor)
		tangent:=state.velocity-[3]f32{0,state.velocity[1],0}
		testing.expect(t,!state.grounded && character_length_3d(tangent-direction*12)<0.01 && character_length_3d(state.inherited_velocity-direction*12)<0.01,"takeoff retains the support's full world velocity")
		offset:=feet.position-platform.position-start; offset[1]=0
		testing.expect(t,character_length_3d(offset)<0.015,"takeoff does not apply support carry a second time")
		landed:=false
		for frame in 0..<90 {
			physics_3d_update(&w,Physics3D_Fixed_Delta)
			state,_=get_character_controller_3d_state(&w,actor)
			platform,_=get_transform(&w,carrier); feet,_=get_transform(&w,actor)
			offset=feet.position-platform.position-start; offset[1]=0
			testing.expect(t,character_length_3d(offset)<0.03,"neutral input retains the same cabin-local point during ascent, descent and after landing")
			if state.grounded {
				landed=true
				testing.expect(t,state.support_entity==carrier && character_length_3d(state.velocity)<0.02,"landing converts inherited world momentum back into support-relative ground velocity")
			} else {
				tangent=state.velocity-[3]f32{0,state.velocity[1],0}
				testing.expect(t,character_length_3d(tangent-direction*12)<0.01,"air control does not brake away inherited support momentum")
			}
		}
		testing.expect(t,landed,"the neutral jump returns to the moving floor")
	}
}

@(test)
character_controller_3d_walk_off_retains_support_momentum_when_platform_changes_velocity :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	carrier:=character_support_momentum_test_box(&w,&r,{0,-0.25,0},{4,0.5,20},{0,0,12})
	actor:=character_support_momentum_test_actor(&w,&r,{0,0.025,0})
	for _ in 0..<12 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	assert(character_controller_3d_move(&w,actor,{1,0}))
	departed:=false
	for _ in 0..<90 {
		physics_3d_update(&w,Physics3D_Fixed_Delta)
		state,_:=get_character_controller_3d_state(&w,actor)
		if !state.grounded {departed=true; break}
	}
	if !testing.expect(t,departed,"walking past a finite moving floor releases support") {return}
	state,_:=get_character_controller_3d_state(&w,actor)
	testing.expect(t,state.support_entity==0 && abs(state.inherited_velocity[2]-12)<0.01 && abs(state.velocity[2]-12)<0.01)
	body,_:=get(&w,carrier,RigidBody3D); body.velocity={0,0,-6}; assert(set(&w,carrier,body))
	assert(character_controller_3d_move(&w,actor,{}))
	feet,_:=get_transform(&w,actor); start:=feet.position
	for _ in 0..<12 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	state,_=get_character_controller_3d_state(&w,actor); feet,_=get_transform(&w,actor)
	testing.expect(t,!state.grounded && state.support_entity==0 && abs(state.velocity[2]-12)<0.01 && abs(state.inherited_velocity[2]-12)<0.01,"a departed support cannot steer airborne world momentum")
	testing.expect(t,abs(feet.position[2]-start[2]-12*12*Physics3D_Fixed_Delta)<0.02,"airborne displacement includes the inherited forward velocity every step")
}

@(test)
character_controller_3d_inherited_support_velocity_still_collides_with_compound_cabin_walls :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	carrier:=character_support_momentum_test_box(&w,&r,{0,-0.25,0},{8,0.5,12},{0,0,12},true)
	actor:=character_support_momentum_test_actor(&w,&r,{2.8,0.025,0})
	for _ in 0..<12 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	platform,_:=get_transform(&w,carrier); feet,_:=get_transform(&w,actor); start_z:=feet.position[2]-platform.position[2]
	assert(character_controller_3d_move(&w,actor,{1,0}))
	assert(character_controller_3d_jump(&w,actor))
	airborne:=false; blocked:=false
	for _ in 0..<36 {
		physics_3d_update(&w,Physics3D_Fixed_Delta)
		state,_:=get_character_controller_3d_state(&w,actor)
		platform,_=get_transform(&w,carrier); feet,_=get_transform(&w,actor)
		local:=feet.position-platform.position
		testing.expect(t,local[0]<3.5 && abs(local[2]-start_z)<0.03,"airborne movement remains swept against the translating cabin without losing its forward carry")
		if !state.grounded {
			airborne=true
			if local[0]>3.35 {blocked=true}
			testing.expect(t,abs(state.velocity[2]-12)<0.01,"contact with a side rail leaves orthogonal inherited momentum intact")
		}
	}
	testing.expect(t,airborne && blocked,"the jump reaches and is stopped by the real compound side wall")
}
