package ecs

import "core:testing"
import b3 "vendor:box3d"

@(test)
destroy_entities_handles_overlapping_roots_and_native_cleanup :: proc(t:^testing.T) {
	lock_native_physics_test();defer unlock_native_physics_test()
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	parent,child,grandchild,survivor:=create_entity(&w),create_entity(&w),create_entity(&w),create_entity(&w)
	assert(set_parent(&w,child,parent) && set_parent(&w,grandchild,child))
	for entity in ([4]Entity{parent,child,grandchild,survivor}) {assert(add(&w,&r,entity,default_transform()))}
	assert(add(&w,&r,parent,BoxCollider{size={1,1,1},friction=0.8,is_static=true}))
	_ = physics_3d_overlap_box(&w,{},[3]f32{2,2,2})
	native,found:=physics_3d_native_body(&w,parent);assert(found)
	_ = root_entities(&w);version:=w.hierarchy_version
	other:=init();defer destroy(&other)
	stale:=create_entity(&other)
	// Child-first input, repeated roots, and a handle from another World.
	roots:=[6]Entity{child,parent,grandchild,child,0,stale}
	testing.expect(t,destroy_entities(&w,roots[:])==3 && w.entity_count==1)
	testing.expect(t,is_alive(&w,survivor) && !is_alive(&w,parent) && !b3.Body_IsValid(native))
	testing.expect(t,len(w.transforms)==1 && len(w.box3d_bodies)==0)
	testing.expect(t,w.component_changes[{entity=grandchild,name="Transform"}].version<w.component_changes[{entity=child,name="Transform"}].version &&
		w.component_changes[{entity=child,name="Transform"}].version<w.component_changes[{entity=parent,name="Transform"}].version,"descendants detach before ancestors regardless of input order")
	testing.expect(t,w.hierarchy_version==version,"batch removal does not rebuild between roots")
	testing.expect(t,len(root_entities(&w))==1 && w.hierarchy_version==version+1)
	testing.expect(t,destroy_entities(&w,roots[:])==0 && destroy_entities(&w,nil)==0)
}

@(test)
lifetime_batch_expiry_preserves_disabled_entities_and_removes_subtrees :: proc(t:^testing.T) {
	w:=init();defer destroy(&w)
	r:=init_registry();defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	parent,child,suspended:=create_entity(&w),create_entity(&w),create_entity(&w)
	assert(set_parent(&w,child,parent))
	for entity in ([3]Entity{parent,child,suspended}) {assert(add(&w,&r,entity,Lifetime{seconds=1}))}
	assert(set_enabled(&w,suspended,false))
	for _ in 0..<256 {entity:=create_entity(&w);assert(add(&w,&r,entity,Lifetime{seconds=1}))}
	for _ in 0..<1024 {_ = create_entity(&w)}
	_ = root_entities(&w);version:=w.hierarchy_version
	update_lifetimes(&w,0.5)
	testing.expect(t,is_alive(&w,parent) && w.lifetime_elapsed[parent]==0.5 && w.lifetime_elapsed[suspended]==0)
	update_lifetimes(&w,0.5)
	testing.expect(t,w.entity_count==1025 && !is_alive(&w,child) && is_alive(&w,suspended))
	testing.expect(t,w.hierarchy_version==version && len(w.lifetimes)==1,"simultaneous expiry gathers one hierarchy snapshot")
	assert(set_enabled(&w,suspended,true))
	update_lifetimes(&w,1)
	testing.expect(t,!is_alive(&w,suspended) && w.entity_count==1024)
}
