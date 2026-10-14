package ecs

import "core:testing"

@(test)
physics_3d_sphere_cast_respects_radius_closest_hit_filters_and_bounds :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	entities:[3]Entity
	for x,index in ([3]f32{2,5,1}) {
		entities[index]=create_entity(&w)
		assert(add(&w,&r,entities[index],Transform{position={x,0,0},scale={1,2,2}}))
		assert(add(&w,&r,entities[index],BoxCollider{size={0.05,1,1},is_static=true,is_sensor=index==2}))
	}
	origin:=[3]f32{0,0,1.04}; delta:=[3]f32{10,0,0}
	_,ray_hit:=physics_3d_raycast(&w,origin,delta,{layers=~u64(0),include_sensors=false})
	testing.expect(t,!ray_hit,"a centre ray misses the wall edge")
	hit,ok:=physics_3d_sphere_cast(&w,origin,delta,0.16,{layers=~u64(0),include_sensors=false})
	testing.expect(t,ok && hit.entity==entities[0] && hit.fraction<0.2,"the finite sphere contacts the nearest edge")
	hit,ok=physics_3d_sphere_cast(&w,origin,delta,0.16,{layers=~u64(0),include_sensors=false,ignore=entities[0]})
	testing.expect(t,ok && hit.entity==entities[1],"ignored solids do not hide farther hits")
	hit,ok=physics_3d_sphere_cast(&w,origin,delta,0.16)
	testing.expect(t,ok && hit.entity==entities[2],"sensor inclusion follows the supplied filter")
	_,ok=physics_3d_sphere_cast(&w,origin,{1,0,0},0.16,{layers=~u64(0),include_sensors=false})
	testing.expect(t,!ok,"casts do not extend beyond the requested translation")
	_,ok=physics_3d_sphere_cast(&w,origin,delta,0)
	testing.expect(t,!ok,"zero radius follows the centre-ray behavior")
	_,ok=physics_3d_sphere_cast(&w,origin,delta,-1)
	testing.expect(t,!ok,"invalid radii are rejected")
}
