package ecs

import "core:math/linalg"
import "core:testing"
import b3 "vendor:box3d"

@(test)
physics_3d_syncs_rotating_dynamic_and_kinematic_poses :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w := init(); defer destroy(&w)
	r := init_registry(); defer destroy_registry(&r)
	testing.expect(t, register_builtin_components(&r))
	for body_type in ([2]string{"dynamic", "kinematic"}) {
		entity := create_entity(&w)
		initial := Transform{rotation={20,35,-15},scale={1,1,1}}
		testing.expect(t, add(&w,&r,entity,initial))
		testing.expect(t, add(&w,&r,entity,BoxCollider{size={1,1,1}}))
		testing.expect(t, add(&w,&r,entity,RigidBody3D{
			body_type=body_type,angular_velocity={0.7,-0.45,0.25},gravity_scale=0,
		}))
		// Keep the fixtures apart so rotation comes from the prescribed angular
		// velocity rather than a contact between the two bodies.
		pose := initial; pose.position = {0,0,f32(entity_index(entity))*3}
		testing.expect(t, set_transform(&w,entity,pose))
		for step in 0..<30 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
		native, found := physics_3d_native_body(&w,entity)
		testing.expect(t,found); if !found {continue}
		actual, has_transform := get_transform(&w,entity)
		testing.expect(t,has_transform && actual.rotation != initial.rotation,
			"physical angular motion changes the rendered Transform")
		rotation := b3.Body_GetRotation(native)
		for axis in ([3][3]f32{{1,0,0},{0,1,0},{0,0,1}}) {
			expected := linalg.quaternion_mul_vector3(rotation,axis)
			rendered := compose_transform_3d(Transform{rotation=actual.rotation,scale={1,1,1}},Transform{position=axis,scale={1,1,1}}).position
			testing.expect(t,linalg.length(rendered-expected)<0.0001,
				"rendered orientation follows native collision orientation on every axis")
		}
	}
}

@(test)
physics_3d_retains_authored_euler_values_without_angular_motion :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w := init(); defer destroy(&w)
	r := init_registry(); defer destroy_registry(&r)
	testing.expect(t,register_builtin_components(&r))
	for body_type in ([3]string{"dynamic","kinematic","static"}) {
		for authored in ([3][3]f32{{10,400,15},{0,90,0},{20,-270,-400}}) {
			entity := create_entity(&w)
			testing.expect(t,add(&w,&r,entity,Transform{position={0,0,f32(entity_index(entity))*3},rotation=authored,scale={1,1,1}}))
			testing.expect(t,add(&w,&r,entity,BoxCollider{size={1,1,1}}))
			testing.expect(t,add(&w,&r,entity,RigidBody3D{body_type=body_type,gravity_scale=0}))
			for step in 0..<4 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
			actual,found := get_transform(&w,entity)
			testing.expect(t,found && actual.rotation==authored,
				"idle physics preserves equivalent authored Euler representations exactly")
			actual.rotation={-15,280,20}
			testing.expect(t,set_transform(&w,entity,actual))
			physics_3d_update(&w,Physics3D_Fixed_Delta)
			updated,_ := get_transform(&w,entity)
			testing.expect(t,updated.rotation==actual.rotation,
				"manual rotation edits remain authoritative when angular velocity is zero")
		}
	}
}
