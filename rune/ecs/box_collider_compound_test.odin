package ecs

import "core:encoding/json"
import "core:testing"
import "rune:navigation"

@(test)
box_collider_additional_boxes_are_owned_validated_and_snapshotted :: proc(t:^testing.T) {
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	e:=create_entity(&w); assert(add(&w,&r,e,Transform{scale={1,1,1}}))
	parts:=[2]BoxCollider_Box{{offset={-2,1,0},size={0.2,2,4}},{offset={2,1,0},size={0.2,2,4}}}
	assert(add(&w,&r,e,BoxCollider{size={4,0.5,4},additional_boxes=parts[:]}))
	parts[0].offset[0]=-100
	stored,_:=get_box_collider(&w,e)
	testing.expect(t,len(stored.additional_boxes)==2 && stored.additional_boxes[0].offset[0]==-2,"typed add copies caller-owned boxes")
	stored.friction=0.9
	assert(set_box_collider(&w,e,stored))
	stored,_=get_box_collider(&w,e)
	testing.expect(t,stored.additional_boxes[0].offset[0]==-2,"scalar edits can safely reuse a getter's borrowed box slice")
	value,ok:=runtime_component_json(&w,e,"BoxCollider")
	testing.expect(t,ok)
	restored,valid:=box_collider_from_json(value)
	testing.expect(t,valid && box_colliders_equal(stored,restored),"runtime snapshots preserve compound geometry")
	bad:=stored; bad.additional_boxes=parts[:]; parts[1].size[1]=0
	testing.expect(t,!set_box_collider(&w,e,bad),"invalid dimensions are rejected before replacing owned storage")
	stored,_=get_box_collider(&w,e)
	testing.expect(t,stored.additional_boxes[1].size[1]==2)
	oversized:=[MAX_ADDITIONAL_COLLIDER_BOXES+1]BoxCollider_Box{}
	bad.additional_boxes=oversized[:]
	testing.expect(t,!component_value_valid(bad),"the compound shape count is bounded")
	for text in ([]string{`{"additional_boxes":[{"size":[1,0,1]}]}`,`{"additional_boxes":[{"offset":[0,0]}]}`,`{"additional_boxes":[{"rotation":[0,0,0]}]}`,`{"additional_boxes":true}`}) {
		data:json.Value; assert(json.unmarshal(transmute([]u8)text,&data,allocator=context.temp_allocator)==nil)
		_,valid:=box_collider_from_json(data); testing.expect(t,!valid)
	}
	legacy,encoded:=component_value_json(BoxCollider{size={1,1,1}})
	_,valid=box_collider_from_json(legacy)
	testing.expect(t,encoded && valid,"empty additional boxes preserve old typed callers")
	remove_component(&w,e,"BoxCollider")
	testing.expect(t,!has_component_data(&w,e,"BoxCollider"))
}

@(test)
box_collider_additional_boxes_scale_rotate_and_rebuild_with_the_owner :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	e:=create_entity(&w)
	pose:=Transform{position={7,0,11},rotation={0,90,0},scale={2,1,1}}
	assert(add(&w,&r,e,pose))
	parts:=[1]BoxCollider_Box{{offset={2,14.7,0},size={0.2,1,1}}}
	assert(add(&w,&r,e,BoxCollider{size={1,0.1,1},is_static=true,additional_boxes=parts[:]}))
	center,axis:[3]f32
	for rotation in ([3][3]f32{{0,90,0},{15,37,-12},{-22,64,17}}) {
		pose.rotation=rotation; assert(set_transform(&w,e,pose))
		center=box_collider_box_transform(pose,parts[0]).position
		axis=compose_transform_3d(Transform{rotation=pose.rotation,scale={1,1,1}},Transform{position={1,0,0},scale={1,1,1}}).position
		hit,found:=physics_3d_raycast(&w,center-axis*2,axis*4)
		testing.expect(t,found && hit.entity==e && hit.component=="BoxCollider" && abs(hit.fraction-0.45)<0.0001,"local offsets and dimensions match composed transforms even far from an arbitrarily rotated owner")
		geometry,error:=collect_navigation_geometry_3d(&w,".")
		testing.expect(t,error=="" && len(geometry.vertices)==16,"static navigation bakes every box on the owner")
		if len(geometry.vertices)==16 {
			// The second box's -X face is the visible plane crossed by the ray.
			face:=(geometry.vertices[8]+geometry.vertices[11]+geometry.vertices[12]+geometry.vertices[15])*0.25
			expected:=center-axis*(parts[0].size[0]*pose.scale[0]*0.5)
			for coordinate,index in expected {
				testing.expect(t,found && abs(hit.point[index]-coordinate)<0.0005 && abs(face[index]-coordinate)<0.0005,"native hits, rendered transforms and baked navigation share the same offset box face")
			}
		}
		navigation.destroy_bake_geometry_3d(&geometry)
	}
	collider,_:=get_box_collider(&w,e)
	collider.additional_boxes=nil
	assert(set_box_collider(&w,e,collider))
	_,found:=physics_3d_raycast(&w,center-axis*2,axis*4)
	testing.expect(t,!found,"editing compound geometry removes stale native shapes")
	counters,valid:=physics_3d_counters(&w)
	testing.expect(t,valid && counters.bodyCount==1 && counters.shapeCount==1)
	destroy_entity(&w,e)
	counters,valid=physics_3d_counters(&w)
	testing.expect(t,valid && counters.bodyCount==0 && counters.shapeCount==0,"entity teardown releases the entire native body")
}

@(test)
box_collider_kinematic_compound_carries_capsule_and_blocks_rails_and_roof :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r); assert(register_builtin_components(&r))
	carrier:=create_entity(&w)
	assert(add(&w,&r,carrier,Transform{position={0,-0.25,0},scale={1,1,1}}))
	parts:=[5]BoxCollider_Box{
		{offset={-2.9,1.25,0},size={0.2,2,6}}, {offset={2.9,1.25,0},size={0.2,2,6}},
		{offset={0,1.25,-2.9},size={6,2,0.2}}, {offset={0,1.25,2.9},size={6,2,0.2}},
		{offset={0,3.25,0},size={6,0.3,6}},
	}
	assert(add(&w,&r,carrier,BoxCollider{size={6,0.5,6},additional_boxes=parts[:]}))
	assert(add(&w,&r,carrier,RigidBody3D{body_type="kinematic",gravity_scale=0}))
	actor:=create_entity(&w)
	assert(add(&w,&r,actor,Transform{position={0,0.025,0},scale={1,1,1}}))
	assert(add(&w,&r,actor,default_character_controller_3d()))
	for frame in 0..<12 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	state,_:=get_character_controller_3d_state(&w,actor)
	testing.expect(t,state.grounded && state.support_entity==carrier)
	body,_:=get(&w,carrier,RigidBody3D); body.velocity={2,0,0}; assert(set(&w,carrier,body))
	assert(character_controller_3d_move(&w,actor,{1,0}))
	for frame in 0..<120 {physics_3d_update(&w,Physics3D_Fixed_Delta)}
	platform,_:=get_transform(&w,carrier); feet,_:=get_transform(&w,actor)
	state,_=get_character_controller_3d_state(&w,actor)
	testing.expect(t,abs(platform.position[0]-4)<0.01 && state.grounded && state.support_entity==carrier,"one kinematic body carries the rider and all its rail shapes")
	testing.expect(t,feet.position[0]>platform.position[0]+2 && feet.position[0]<platform.position[0]+2.5,"walking cannot cross a solid rail")
	body.velocity={}; assert(set(&w,carrier,body)); assert(character_controller_3d_move(&w,actor,{}))
	assert(character_controller_3d_jump(&w,actor))
	highest:=feet.position[1]
	for frame in 0..<100 {
		physics_3d_update(&w,Physics3D_Fixed_Delta)
		feet,_=get_transform(&w,actor); highest=max(highest,feet.position[1])
	}
	state,_=get_character_controller_3d_state(&w,actor)
	testing.expect(t,highest>0.1 && highest<1.1 && state.grounded && state.support_entity==carrier,"the compound roof blocks a real capsule jump without losing floor support")
	counters,valid:=physics_3d_counters(&w)
	testing.expect(t,valid && counters.bodyCount==1 && counters.shapeCount==6,"floor, rails, and roof share one native body")
}
