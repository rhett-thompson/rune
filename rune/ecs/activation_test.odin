package ecs

import "core:testing"

@(test)
visual_activation_reuses_native_collision_and_groups_toggle_descendant_bodies :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r);assert(register_builtin_components(&r))
	visual:=create_entity(&w);assert(add(&w,&r,visual,default_transform()))
	visual_child:=create_entity(&w)
	assert(add(&w,&r,visual_child,default_transform()) && set_parent(&w,visual_child,visual))
	group:=create_entity(&w);assert(add(&w,&r,group,default_transform()))
	body_3d:=create_entity(&w)
	assert(add(&w,&r,body_3d,Transform{position={5,0,0},scale={1,1,1}}) && set_parent(&w,body_3d,group))
	assert(add(&w,&r,body_3d,BoxCollider{size={1,1,1},is_static=true}))
	body_2d:=create_entity(&w)
	assert(add(&w,&r,body_2d,Transform{position={10,0,0},scale={1,1,1}}) && set_parent(&w,body_2d,group))
	assert(add(&w,&r,body_2d,BoxCollider2D{size={1,1}}))
	hit_3d,found_3d:=physics_3d_raycast(&w,{5,2,0},{0,-4,0})
	hit_2d,found_2d:=physics_2d_raycast(&w,{10,2},{0,-4})
	testing.expect(t,found_3d && hit_3d.entity==body_3d && found_2d && hit_2d.entity==body_2d,"both descendants begin with queryable native collision")
	count:=w.physics_3d.sync_count
	for _ in 0..<10 {for enabled in ([2]bool{false,true}) {
		assert(set_enabled(&w,visual,enabled))
		testing.expect(t,is_enabled(&w,visual_child)==enabled,"visual activation still reaches the full subtree")
		testing.expect(t,!w.physics_2d.needs_sync && !w.physics_3d.needs_sync,"visual-only activation leaves both physics worlds synchronized")
		hit_3d,found_3d=physics_3d_raycast(&w,{5,2,0},{0,-4,0})
		hit_2d,found_2d=physics_2d_raycast(&w,{10,2},{0,-4})
		testing.expect(t,found_3d && hit_3d.entity==body_3d && found_2d && hit_2d.entity==body_2d && w.physics_3d.sync_count==count,"visual toggles reuse unchanged query collision")
	}}
	assert(set_enabled(&w,group,false))
	_,native_3d:=w.box3d_bodies[body_3d];_,native_2d:=w.box2d_bodies[body_2d]
	testing.expect(t,!native_3d && !native_2d,"disabling a collision-free group immediately removes both native descendants")
	_,found_3d=physics_3d_raycast(&w,{5,2,0},{0,-4,0})
	_,found_2d=physics_2d_raycast(&w,{10,2},{0,-4})
	testing.expect(t,!found_3d && !found_2d,"disabled descendants cannot be queried before a simulation step")
	assert(set_enabled(&w,body_3d,false))
	assert(set_enabled(&w,group,true))
	_,found_3d=physics_3d_raycast(&w,{5,2,0},{0,-4,0})
	hit_2d,found_2d=physics_2d_raycast(&w,{10,2},{0,-4})
	testing.expect(t,!found_3d && found_2d && hit_2d.entity==body_2d,"group reactivation restores bodies while preserving a child's own disabled state")
	assert(set_enabled(&w,body_3d,true))
	hit_3d,found_3d=physics_3d_raycast(&w,{5,2,0},{0,-4,0})
	testing.expect(t,found_3d && hit_3d.entity==body_3d,"reactivating the remaining child restores its collision before simulation")
}
