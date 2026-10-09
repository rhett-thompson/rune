package r3d_bridge

import "core:testing"
import "rune:ecs"

@(test)
light_shaft_source_follows_rendered_hierarchy_and_stable_ids :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	root:=ecs.create_entity(&w)
	ecs.add(&w,&r,root,ecs.Transform{position={10,20,30},rotation={0,90,0},scale={2,3,4}})
	gap:=ecs.create_entity(&w); ecs.set_parent(&w,gap,root)
	source:=ecs.create_entity(&w); ecs.set_parent(&w,source,gap)
	ecs.add(&w,&r,source,ecs.Transform{position={1,2,3},scale={1,1,1}})
	ecs.set_entity_metadata(&w,source,"shaft_source","","",ecs.Default_Layer_Mask)
	position,valid:=light_shaft_source(&w,"shaft_source")
	testing.expect(t,valid)
	expected:=[3]f32{22,26,28}
	for axis in 0..<3 {testing.expect(t,abs(position[axis]-expected[axis])<0.001)}
	// Direct parent edits must be visible without a cached handle or dirty call.
	w.transforms[root]=ecs.Transform{position={-10,0,5},rotation={0,180,0},scale={3,2,1}}
	position,valid=light_shaft_source(&w,"shaft_source")
	testing.expect(t,valid)
	expected={-13,4,2}
	for axis in 0..<3 {testing.expect(t,abs(position[axis]-expected[axis])<0.001)}
	ecs.set_enabled(&w,root,false)
	_,valid=light_shaft_source(&w,"shaft_source")
	testing.expect(t,!valid,"disabled ancestors hide their source")
	ecs.set_enabled(&w,root,true)
	ecs.destroy_entity(&w,source)
	_,valid=light_shaft_source(&w,"shaft_source")
	testing.expect(t,!valid,"destroying a source must not leave a stale handle")
	replacement:=ecs.create_entity(&w)
	ecs.add(&w,&r,replacement,ecs.Transform{position={7,8,9},scale={1,1,1}})
	ecs.set_entity_metadata(&w,replacement,"shaft_source","","",ecs.Default_Layer_Mask)
	position,valid=light_shaft_source(&w,"shaft_source")
	testing.expect(t,valid && position==[3]f32{7,8,9},"reload resolves the current entity by ID")
}
