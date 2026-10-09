package ecs

import "core:testing"

@(test)
trigger_center_follows_scaled_rotated_ancestors :: proc(t:^testing.T) {
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r)
	testing.expect(t,register_builtin_components(&r))
	parent:=create_entity(&w)
	testing.expect(t,add(&w,&r,parent,Transform{position={10,0,10},rotation={0,90,0},scale={2,3,4}}))
	gap:=create_entity(&w); testing.expect(t,set_parent(&w,gap,parent))
	zone:=create_entity(&w); testing.expect(t,set_parent(&w,zone,gap))
	testing.expect(t,add(&w,&r,zone,Transform{position={1,1,0},scale={0.5,1,0.25}}))
	value:=Default_Trigger_3D; value.offset={0,0.5,0}
	testing.expect(t,add(&w,&r,zone,value))
	center,half_size,radius,valid:=trigger_geometry_3d(&w,zone,value)
	testing.expect(t,valid)
	expected:=[3]f32{10,3.5,8}
	for axis in 0..<3 {testing.expect(t,abs(center[axis]-expected[axis])<0.001)}
	testing.expect(t,half_size==([3]f32{1,3,1}) && radius==3,
		"dimensions retain hierarchy scale and offset remains world-axis aligned")
	actor:=create_entity(&w)
	testing.expect(t,add(&w,&r,actor,Transform{position={10,3,8},scale={1,1,1}}))
	testing.expect(t,add(&w,&r,actor,default_character_controller_3d()))
	update_triggers_3d(&w)
	testing.expect(t,trigger_contains_3d(&w,zone,actor),"a root-space capsule enters the visible zone")
	// Movement and reparenting affect detection without editing the local zone.
	pose,_:=get_transform(&w,parent); pose.position.y+=5
	testing.expect(t,set_transform(&w,parent,pose))
	center,_,_,valid=trigger_geometry_3d(&w,zone,value)
	testing.expect(t,valid && abs(center.y-8.5)<0.001)
	update_triggers_3d(&w)
	testing.expect(t,!trigger_contains_3d(&w,zone,actor) && len(trigger_events_3d(&w))==1 && trigger_events_3d(&w)[0].kind==.Exit,
		"moving the parent away emits an exit at the previous world location")
	testing.expect(t,set_parent(&w,zone,0))
	center,half_size,radius,valid=trigger_geometry_3d(&w,zone,value)
	testing.expect(t,valid && center==([3]f32{1,1.5,0}) && half_size==([3]f32{0.5,1,0.25}) && radius==1)
}
