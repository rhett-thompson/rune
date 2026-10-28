package ecs

import "core:math"
import "core:testing"
import "rune:geometry"

@(test)
static_mesh_opacity_is_validated_draw_only_state_that_resets_on_replacement :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r);assert(register_builtin_components(&r))
	entity:=create_entity(&w);assert(add(&w,&r,entity,default_transform()))
	mesh:geometry.Mesh;defer geometry.destroy_mesh(&mesh)
	for point in ([3][3]f32{{0,0,0},{0,0,2},{2,0,0}}) {
		append(&mesh.vertices,geometry.Vertex{position=point,normal={0,1,0},color={255,255,255,255}})
	}
	append(&mesh.indices,0,1,2)
	testing.expect(t,!set_static_mesh_opacity(&w,entity,0.5),"an entity needs installed geometry")
	assert(set_static_mesh(&w,entity,mesh))
	before:=w.static_meshes[entity]
	testing.expect(t,before.opacity==1,"new geometry starts fully opaque")
	assert(set_static_mesh_opacity(&w,entity,0.4))
	after:=w.static_meshes[entity]
	testing.expect(t,after.opacity==0.4 && after.revision==before.revision && after.mesh==before.mesh &&
		raw_data(after.data.vertices)==raw_data(before.data.vertices),"opacity leaves render buffers and native collision untouched")
	for invalid in ([4]f32{-0.1,1.1,math.nan_f32(),math.inf_f32(1)}) {
		testing.expect(t,!set_static_mesh_opacity(&w,entity,invalid) && w.static_meshes[entity].opacity==0.4,"invalid edits are atomic")
	}
	assert(set_static_mesh_opacity(&w,entity,0))
	hit,found:=physics_3d_raycast(&w,{0.5,1,0.5},{0,-2,0})
	testing.expect(t,found && hit.entity==entity,"invisible geometry retains its collision contract")
	assert(set_static_mesh(&w,entity,mesh,collidable=false))
	testing.expect(t,w.static_meshes[entity].opacity==1,"replacement resets transient draw opacity")
	remove_static_mesh(&w,entity)
	testing.expect(t,!set_static_mesh_opacity(&w,entity,0.5) && !set_static_mesh_opacity(nil,entity,0.5))
}
