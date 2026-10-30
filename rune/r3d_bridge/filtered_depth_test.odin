package r3d_bridge

import "core:testing"
import "rune:ecs"
import rl "vendor:raylib"

@(test)
depth_pass_filter_excludes_only_requested_entities_and_descendants :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	root:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,root,ecs.default_transform()))
	gap:=ecs.create_entity(&w);assert(ecs.set_parent(&w,gap,root))
	child:=ecs.create_entity(&w);assert(ecs.set_parent(&w,child,gap))
	assert(ecs.add(&w,&r,child,ecs.default_transform()))
	assert(ecs.add(&w,&r,child,ecs.MeshRenderer{primitive="cube",material="shared.material.json"}))
	sibling:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,sibling,ecs.default_transform()))
	assert(ecs.add(&w,&r,sibling,ecs.MeshRenderer{primitive="cube",material="shared.material.json"}))
	ignored:=[1]ecs.Entity{root}
	filter:=Depth_Pass_Filter{ignored_subtrees=ignored[:]}
	testing.expect(t,depth_pass_excludes(&w,root,filter) && depth_pass_excludes(&w,gap,filter) && depth_pass_excludes(&w,child,filter),"A requested subtree includes its root and descendants across transform-free groups")
	testing.expect(t,!depth_pass_excludes(&w,sibling,filter),"Another renderer sharing the same material stays included")
	testing.expect(t,depth_pass_filter_effective(&w,filter),"A non-rendering group is effective when it contains a visible renderer")
	testing.expect(t,!depth_pass_excludes(&w,child,{}),"An absent filter preserves the existing depth policy")
	ignored[0]=child
	testing.expect(t,!depth_pass_excludes(&w,root,filter) && !depth_pass_excludes(&w,gap,filter) && depth_pass_excludes(&w,child,filter),"Excluding one leaf never excludes its ancestors")
	material,_:=ecs.get_mesh_renderer(&w,child)
	testing.expect(t,material.material=="shared.material.json" && ecs.is_enabled(&w,child),"Depth selection does not mutate material assignment or entity activation")
}

@(test)
depth_pass_filter_ignores_empty_stale_disabled_and_nonrendering_subtrees :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	testing.expect(t,!depth_pass_filter_effective(&w,{}))
	group:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,group,ecs.default_transform()))
	ignored:=[3]ecs.Entity{0,group,0}
	filter:=Depth_Pass_Filter{ignored_subtrees=ignored[:]}
	testing.expect(t,!depth_pass_filter_effective(&w,filter),"A transform-only subtree does not require a second depth pass")
	child:=ecs.create_entity(&w);assert(ecs.set_parent(&w,child,group))
	assert(ecs.add(&w,&r,child,ecs.default_transform()))
	assert(ecs.add(&w,&r,child,ecs.MeshRenderer{primitive="cube"}))
	testing.expect(t,depth_pass_filter_effective(&w,filter))
	assert(ecs.set_enabled(&w,group,false))
	testing.expect(t,!depth_pass_filter_effective(&w,filter),"Disabled ancestors make excluded geometry irrelevant")
	assert(ecs.set_enabled(&w,group,true))
	assert(ecs.set_enabled(&w,child,false))
	testing.expect(t,!depth_pass_filter_effective(&w,filter),"A locally disabled renderer also needs no extra pass")
	assert(ecs.set_enabled(&w,child,true))
	testing.expect(t,depth_pass_filter_effective(&w,filter))
	assert(ecs.destroy_entity(&w,group))
	testing.expect(t,!depth_pass_filter_effective(&w,filter),"Destroyed roots cannot leave a stale pass request")
	replacement:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,replacement,ecs.default_transform()))
	assert(ecs.add(&w,&r,replacement,ecs.MeshRenderer{primitive="cube"}))
	testing.expect(t,!depth_pass_excludes(&w,replacement,filter) && !depth_pass_filter_effective(&w,filter),"Reused entity slots do not inherit an old handle's exclusion")
}

@(test)
depth_pass_render_rejects_uninitialized_context_and_zero_view_teardown_is_safe :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,entity,ecs.default_transform()))
	assert(ecs.add(&w,&r,entity,ecs.MeshRenderer{primitive="cube"}))
	ignored:=[1]ecs.Entity{entity}
	filter:=Depth_Pass_Filter{ignored_subtrees=ignored[:]}
	view:Depth_Pass3D
	ctx:Context
	camera:=rl.Camera3D{position={0,0,5},target={},up={0,1,0},fovy=60,projection=.PERSPECTIVE}
	entity_count:=w.entity_count
	ctx.initialized=true
	testing.expect(t,!render_scene_depth(&view,&ctx,&w,nil,camera,{},0),"An empty filter short-circuits before accessing the GPU even with an initialized bridge")
	testing.expect(t,view.target.id==0 && view.target.texture.id==0 && !view.valid,"The default path allocates no depth target")
	ctx.initialized=false
	testing.expect(t,!render_scene_depth(&view,&ctx,&w,nil,camera,filter,0),"A real exclusion still cannot render through an uninitialized bridge")
	testing.expect(t,view.target.id==0 && view.target.texture.id==0 && !view.valid)
	testing.expect(t,w.entity_count==entity_count && ecs.is_enabled(&w,entity),"Rejected passes leave the live scene untouched")
	destroy_depth_pass_3d(&view)
	destroy_depth_pass_3d(&view)
}
