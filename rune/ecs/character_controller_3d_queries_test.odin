package ecs

import "core:testing"

@(test)
character_controller_3d_rays_use_current_posture_padding_and_gravity_frame :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	e:=create_entity(&w); assert(add(&w,&r,e,Transform{position={10,2,0},scale={1,1,1}}))
	assert(add(&w,&r,e,default_character_controller_3d()))
	hit,ok:=character_controller_3d_raycast(&w,e,{8,3.5,0},{4,0,0})
	testing.expect(t,ok && hit.entity==e && hit.component=="CharacterController3D" && hit.fraction>0 && hit.fraction<0.5,"a bounded segment hits the standing query-only capsule")
	w.character_controller_states_3d[e]={active=true,crouched=true,height=1}
	_,ok=character_controller_3d_raycast(&w,e,{8,3.5,0},{4,0,0})
	testing.expect(t,!ok,"a ray above the crouched head misses")
	_,ok=character_controller_3d_raycast(&w,e,{8,2.5,0.5},{4,0,0})
	testing.expect(t,!ok)
	_,ok=character_controller_3d_raycast(&w,e,{8,2.5,0.5},{4,0,0},0.2)
	testing.expect(t,ok,"projectile padding expands the actual capsule")
	hit,ok=character_controller_3d_raycast(&w,e,{10,2.5,0},{1,0,0})
	testing.expect(t,ok && hit.fraction==0,"a segment beginning inside the capsule reports immediate overlap")
	w.character_controller_states_3d[e]={active=true,height=1.8,up={1,0,0}}
	_,ok=character_controller_3d_raycast(&w,e,{11,2,-2},{0,0,4})
	testing.expect(t,ok,"the query follows a tilted gravity frame")
	_,ok=character_controller_3d_raycast(&w,e,{8,2.5,0},{1,0,0})
	testing.expect(t,!ok,"rays remain bounded by their translation")
	set_enabled(&w,e,false)
	_,ok=character_controller_3d_raycast(&w,e,{8,2,0},{4,0,0})
	testing.expect(t,!ok,"disabled characters cannot be hit")
}
