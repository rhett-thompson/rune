package ecs

import "core:testing"
import "rune:geometry"
import "rune:terrain"

physics_query_sync_surface :: proc(w:^World,r:^Component_Registry,parent:Entity,is_terrain:bool) -> Entity {
	e:=create_entity(w)
	assert(add(w,r,e,default_transform()) && set_parent(w,e,parent))
	if is_terrain {
		assert(add(w,r,e,Terrain{asset="query-sync-fixture",collision=true,friction=0.8}))
		data:=terrain.Data{description={resolution={2,2},size={4,4}},heights=make([]f32,4)}
		mesh:=terrain_collision_mesh(data);assert(mesh!=nil)
		w.terrain_states[e]={data=data,mesh=mesh}
	} else {
		mesh:geometry.Mesh;defer geometry.destroy_mesh(&mesh)
		for p in ([4][3]f32{{0,0,0},{4,0,0},{0,0,4},{4,0,4}}) {
			append(&mesh.vertices,geometry.Vertex{position=p,normal={0,1,0}})
		}
		append(&mesh.indices,0,2,1,1,2,3)
		assert(set_static_mesh(w,e,mesh))
	}
	return e
}

physics_query_sync_expect_surface :: proc(t:^testing.T,w:^World,e:Entity) {
	pose:=world_transform_3d(w,e)
	center:=compose_transform_3d(pose,Transform{position={2,0,2},scale={1,1,1}}).position
	filter:=Physics_Query_Filter{layers=~u64(0),include_sensors=false}
	hit,found:=physics_3d_raycast(w,center+[3]f32{0,2,0},{0,-4,0},filter)
	testing.expect(t,found && hit.entity==e && abs(hit.point.y-center.y)<0.001,"ray uses the current composed surface pose")
	hit,found=physics_3d_sphere_cast(w,center+[3]f32{0,2,0},{0,-4,0},0.1,filter)
	testing.expect(t,found && hit.entity==e,"sphere casts share synchronized mesh collision")
	entities:=physics_3d_overlap_box(w,center,{0.2,0.2,0.2},filter)
	testing.expect(t,len(entities)==1 && entities[0]==e,"overlaps share synchronized mesh collision")
}

@(test)
physics_3d_queries_sync_mesh_batches_once_and_follow_hierarchy_edits :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	for is_terrain in ([2]bool{false,true}) {
		w:=init();defer destroy(&w)
		r:=init_registry();defer destroy_registry(&r);assert(register_builtin_components(&r))
		parent:=create_entity(&w);assert(add(&w,&r,parent,default_transform()))
		e:=physics_query_sync_surface(&w,&r,parent,is_terrain)
		for _ in 0..<20 {physics_query_sync_expect_surface(t,&w,e)}
		testing.expect(t,w.physics_3d.sync_count==1,"unchanged ray, sphere and overlap batches perform one synchronization, even with a mesh present")
		assert(set_transform(&w,parent,Transform{position={8,2,5},rotation={0,90,0},scale={2,1,2}}))
		testing.expect(t,w.physics_3d.needs_sync,"parent edits invalidate composed mesh collision")
		physics_query_sync_expect_surface(t,&w,e)
		testing.expect(t,w.physics_3d.sync_count==2,"one parent edit causes one additional synchronization")
		_,found:=physics_3d_raycast(&w,{2,2,2},{0,-4,0})
		testing.expect(t,!found,"the old location has no stale collision")
		pose,_:=get_transform(&w,e);pose.position={1,1,1};pose.scale={0.5,2,0.5}
		assert(set_transform(&w,e,pose));physics_query_sync_expect_surface(t,&w,e)
		other:=create_entity(&w);assert(add(&w,&r,other,Transform{position={-10,4,0},scale={1,1,1}}))
		assert(set_parent(&w,e,other));physics_query_sync_expect_surface(t,&w,e)
		center:=world_transform_3d(&w,e).position+[3]f32{1,0,1}
		assert(set_entity_layer_mask(&w,e,2))
		_,found=physics_3d_raycast(&w,center+[3]f32{0,2,0},{0,-4,0},{layers=1})
		testing.expect(t,!found,"layer edits take effect before the next simulation step")
		physics_query_sync_expect_surface(t,&w,e)
		assert(set_enabled(&w,other,false))
		_,found=physics_3d_raycast(&w,center+[3]f32{0,2,0},{0,-4,0},{layers=~u64(0)})
		testing.expect(t,!found,"disabling an ancestor removes collision immediately")
		assert(set_enabled(&w,other,true));physics_query_sync_expect_surface(t,&w,e)
		assert(remove_component(&w,other,"Transform"));physics_query_sync_expect_surface(t,&w,e)
		for _ in 0..<20 {physics_query_sync_expect_surface(t,&w,e)}
		testing.expect(t,!w.physics_3d.needs_sync,"queries leave an unchanged world synchronized")
	}
}

@(test)
physics_3d_queries_follow_simulated_mesh_ancestors :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	for is_terrain in ([2]bool{false,true}) {
		w:=init();defer destroy(&w)
		r:=init_registry();defer destroy_registry(&r);assert(register_builtin_components(&r))
		parent:=create_entity(&w)
		assert(add(&w,&r,parent,Transform{position={0,2,0},scale={1,1,1}}))
		assert(add(&w,&r,parent,BoxCollider{size={0.1,0.1,0.1}}))
		assert(add(&w,&r,parent,RigidBody3D{body_type="kinematic",velocity={6,0,0},gravity_scale=0}))
		e:=physics_query_sync_surface(&w,&r,parent,is_terrain)
		physics_query_sync_expect_surface(t,&w,e)
		before:=world_transform_3d(&w,e)
		physics_3d_update(&w,Physics3D_Fixed_Delta)
		after:=world_transform_3d(&w,e)
		testing.expect(t,after.position.x>before.position.x+0.05,"native simulation moves the mesh ancestor")
		testing.expect(t,w.physics_3d.needs_sync,"physics-written ancestor transforms invalidate composed collision")
		physics_query_sync_expect_surface(t,&w,e)
		count:=w.physics_3d.sync_count
		for _ in 0..<20 {physics_query_sync_expect_surface(t,&w,e)}
		testing.expect(t,w.physics_3d.sync_count==count,"queries reuse the synchronized result after simulation")
	}
}
