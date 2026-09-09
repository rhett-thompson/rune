package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "rune:ecs"
import "rune:scene"
import "rune:validation"

parse :: proc(text:string)->json.Value {
	value:json.Value
	assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
	return value
}
add :: proc(w:^ecs.World,r:^ecs.Component_Registry,e:ecs.Entity,name,text:string) {
	assert(ecs.add_component(w,r,e,name,parse(text)),name)
}
box :: proc(w:^ecs.World,r:^ecs.Component_Registry,position,size:[3]f32,rotation:[3]f32={})->ecs.Entity {
	e:=ecs.create_entity(w)
	add(w,r,e,"Transform",`{}`)
	assert(ecs.set_transform(w,e,ecs.Transform{position=position,scale={1,1,1},rotation=rotation}))
	add(w,r,e,"BoxCollider",`{"size":[1,1,1],"is_static":true}`)
	c,_:=ecs.get_box_collider(w,e);c.size=size;assert(ecs.set_box_collider(w,e,c))
	return e
}
player :: proc(w:^ecs.World,r:^ecs.Component_Registry,position:[3]f32={})->ecs.Entity {
	e:=ecs.create_entity(w)
	add(w,r,e,"Transform",`{}`)
	assert(ecs.set_transform(w,e,ecs.Transform{position=position,scale={1,1,1}}))
	assert(ecs.add(w,r,e,ecs.default_character_controller_3d()))
	return e
}
floor :: proc(w:^ecs.World,r:^ecs.Component_Registry)->ecs.Entity {return box(w,r,{0,-0.5,0},{100,1,100})}
step :: proc(w:^ecs.World,count:=1) {for _ in 0..<count {ecs.physics_3d_update(w,1.0/60)}}
state :: proc(w:^ecs.World,e:ecs.Entity)->ecs.Character_Controller_State_3D {s,_:=ecs.get_character_controller_3d_state(w,e);return s}
pose :: proc(w:^ecs.World,e:ecs.Entity)->ecs.Transform {p,_:=ecs.get_transform(w,e);return p}

validate_ground_and_wall :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r)
	box(&w,r,{3,2,0},{0.1,4,20})
	e:=player(&w,r,{0,2,0})
	step(&w,120)
	assert(state(&w,e).grounded,"fall onto floor")
	assert(math.abs(pose(&w,e).position[1])<0.03,"capsule feet on floor")
	assert(ecs.character_controller_3d_move(&w,e,{1,0}))
	step(&w,120)
	assert(pose(&w,e).position[0]<2.62 && pose(&w,e).position[0]>2.4,"wall collision")
	ecs.character_controller_3d_move(&w,e,{1,1})
	step(&w,60)
	assert(pose(&w,e).position[2]>2,"wall sliding")
	fmt.println("PASS ground, wall, and sliding")
}
validate_jump :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r)
	e:=player(&w,r)
	step(&w,3)
	ecs.character_controller_3d_jump(&w,e)
	step(&w)
	assert(!state(&w,e).grounded && state(&w,e).velocity[1]>7,"jump")
	step(&w,180)
	assert(state(&w,e).grounded,"land")
	fmt.println("PASS jumping and landing")
}
validate_slopes_steps :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r)
	// A ten-degree ramp rises toward +X.
	box(&w,r,{5,0.5,0},{8,0.3,3},{0,0,10})
	e:=player(&w,r,{0,0,0})
	step(&w,2)
	ecs.character_controller_3d_move(&w,e,{1,0})
	step(&w,90)
	assert(pose(&w,e).position[0]>6 && pose(&w,e).position[1]>0.7 && state(&w,e).grounded,"walk up rotated ramp")
	w2:=ecs.init();defer ecs.destroy(&w2)
	floor(&w2,r)
	for i in 0..<5 {box(&w2,r,{2+f32(i)*0.65,f32(i+1)*0.1,0},{0.65,f32(i+1)*0.2,3})}
	e2:=player(&w2,r)
	step(&w2,2)
	ecs.character_controller_3d_move(&w2,e2,{1,0})
	step(&w2,60)
	assert(pose(&w2,e2).position[0]>3.5 && pose(&w2,e2).position[1]>0.5,"climb stairs")
	fmt.println("PASS slopes and stairs")
}
validate_crouch :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r)
	box(&w,r,{3,1.6,0},{4,0.4,4})
	e:=player(&w,r)
	step(&w,3)
	ecs.character_controller_3d_crouch(&w,e,true)
	ecs.character_controller_3d_move(&w,e,{1,0})
	step(&w,72)
	assert(state(&w,e).crouched && pose(&w,e).position[0]>2,"crouch movement")
	ecs.character_controller_3d_move(&w,e,{})
	ecs.character_controller_3d_crouch(&w,e,false)
	step(&w,12)
	assert(state(&w,e).stand_blocked && state(&w,e).height<1.1,"blocked standing clearance")
	ecs.character_controller_3d_move(&w,e,{-1,0})
	step(&w,120)
	assert(!state(&w,e).crouched && !state(&w,e).stand_blocked,"stand after leaving ceiling")
	fmt.println("PASS crouch and overhead clearance")
}
validate_platform :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	platform:=box(&w,r,{0,-0.5,0},{8,1,8})
	add(&w,r,platform,"RigidBody3D",`{"type":"kinematic","velocity":[1,0,0]}`)
	e:=player(&w,r)
	step(&w,120)
	assert(state(&w,e).grounded && pose(&w,e).position[0]>1.8,"moving support carry")
	ecs.character_controller_3d_jump(&w,e)
	step(&w)
	assert(state(&w,e).velocity[0]>0.9,"inherit platform takeoff velocity")
	assert(ecs.destroy_entity(&w,platform))
	step(&w,60)
	assert(!state(&w,e).grounded && state(&w,e).support_entity==0,"removed support")
	fmt.println("PASS moving platform and takeoff")
}
validate_steep :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r)
	box(&w,r,{3,1.5,0},{6,0.3,4},{0,0,65})
	e:=player(&w,r)
	step(&w,3)
	ecs.character_controller_3d_move(&w,e,{1,0},true)
	peak:f32
	for _ in 0..<180 {step(&w);peak=max(peak,pose(&w,e).position[1])}
	assert(peak<0.4,"reject slopes above limit")
	cfg:=ecs.default_character_controller_3d();cfg.move_speed=20;cfg.step_height=0
	ecs.set(&w,e,cfg)
	transform:=pose(&w,e);transform.position={0,0,0};ecs.set_transform(&w,e,transform)
	step(&w,3);ecs.character_controller_3d_move(&w,e,{1,0})
	peak=0
	for _ in 0..<180 {step(&w);peak=max(peak,pose(&w,e).position[1])}
	assert(peak<0.15,"fast horizontal input cannot climb steep slope")
	fmt.println("PASS steep slope limit")
}
validate_data :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	e:=player(&w,r)
	for bad in ([]string{`{"radius":0}`,`{"height":0.1}`,`{"crouch_height":2}`,`{"step_height":2}`,`{"move_speed":-1}`,`{"braking":0}`,`{"max_slope_angle":89}`,`{"jump_buffer_time":2}`,`{"unknown":1}`,`{"grounded":true}`}) {
		assert(!ecs.add_component(&w,r,e,"CharacterController3D",parse(bad)),bad)
	}
	c:=ecs.default_character_controller_3d();c.gravity=math.nan_f32();assert(!ecs.set(&w,e,c))
	assert(!ecs.character_controller_3d_move(&w,e,{math.inf_f32(1),0}))
	data,ok:=ecs.runtime_component_json(&w,e,"CharacterController3D")
	assert(ok && ecs.add_component(&w,r,e,"CharacterController3D",data),"configuration roundtrip")
	step(&w,2)
	assert(state(&w,e).active,"controller works without other bodies")
	assert(ecs.remove_component(&w,e,"CharacterController3D"))
	_,found:=ecs.get_character_controller_3d_state(&w,e);assert(!found)
	assert(ecs.add(&w,r,e,ecs.default_character_controller_3d()))
	assert(state(&w,e).velocity==([3]f32{}),"removal clears runtime state")
	fmt.println("PASS configuration, serialization, and lifecycle")
}
jump_peak :: proc(r:^ecs.Component_Registry,release:bool)->f32 {
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r);e:=player(&w,r);step(&w,3)
	ecs.character_controller_3d_jump(&w,e);step(&w,3)
	if release {ecs.character_controller_3d_release_jump(&w,e)}
	peak:f32
	for _ in 0..<90 {step(&w);peak=max(peak,pose(&w,e).position[1])}
	return peak
}
validate_jump_edges :: proc(r:^ecs.Component_Registry) {
	assert(jump_peak(r,true)<jump_peak(r,false)*0.7,"early release cuts jump")
	w:=ecs.init();defer ecs.destroy(&w)
	box(&w,r,{0,-0.5,0},{2,1,4})
	e:=player(&w,r)
	step(&w,3);ecs.character_controller_3d_move(&w,e,{1,0})
	left:=false
	for _ in 0..<90 {step(&w);if !state(&w,e).grounded {left=true;break}}
	assert(left,"walk off ledge")
	ecs.character_controller_3d_jump(&w,e);step(&w)
	assert(state(&w,e).velocity[1]>7,"coyote jump")
	w2:=ecs.init();defer ecs.destroy(&w2)
	floor(&w2,r);e2:=player(&w2,r,{0,2,0})
	for _ in 0..<120 {step(&w2);if pose(&w2,e2).position[1]<0.2 {break}}
	ecs.character_controller_3d_jump(&w2,e2)
	jumped:=false
	for _ in 0..<12 {step(&w2);if state(&w2,e2).velocity[1]>7 {jumped=true}}
	assert(jumped,"buffer jump before landing")
	fmt.println("PASS jump cut, coyote time, and jump buffering")
}
validate_timing_and_filtering :: proc(r:^ecs.Component_Registry) {
	a:=ecs.init();defer ecs.destroy(&a)
	b:=ecs.init();defer ecs.destroy(&b)
	floor(&a,r);floor(&b,r)
	ea:=player(&a,r);eb:=player(&b,r)
	ecs.character_controller_3d_move(&a,ea,{0.5,0})
	ecs.character_controller_3d_move(&b,eb,{0.5,0})
	for _ in 0..<60 {ecs.physics_3d_update(&a,1.0/30)}
	for _ in 0..<240 {ecs.physics_3d_update(&b,1.0/120)}
	assert(math.abs(pose(&a,ea).position[0]-pose(&b,eb).position[0])<0.001,"fixed-step frame partition")
	assert(pose(&a,ea).position[0]>4.5 && pose(&a,ea).position[0]<5.1,"analog strength")
	ecs.character_controller_3d_move(&a,ea,{})
	step(&a,30);assert(math.abs(state(&a,ea).velocity[0])<0.001,"braking")
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r)
	ignored:=box(&w,r,{1,1,0},{0.1,2,4})
	ecs.set_entity_layer_mask(&w,ignored,2)
	sensor:=box(&w,r,{2,1,0},{0.1,2,4})
	c,_:=ecs.get_box_collider(&w,sensor);c.is_sensor=true;ecs.set_box_collider(&w,sensor,c)
	box(&w,r,{5,2,0},{0.05,4,4})
	e:=player(&w,r)
	cfg:=ecs.default_character_controller_3d();cfg.move_speed=200;cfg.acceleration=100000
	assert(ecs.set(&w,e,cfg))
	step(&w,3);ecs.character_controller_3d_move(&w,e,{1,0});step(&w,4)
	assert(pose(&w,e).position[0]>4.4 && pose(&w,e).position[0]<4.7,"layers/sensors ignored; thin wall blocks fast movement")
	fmt.println("PASS fixed-step timing, analog input, braking, filtering, and fast casts")
}
validate_lifecycle :: proc(r:^ecs.Component_Registry) {
	w,loaded:=scene.load("tools/character_controller_3d_validation/fixtures/main.scene.json",r)
	assert(loaded,scene.last_load_error());defer ecs.destroy(&w)
	e,_:=ecs.find_entity_by_id(&w,"player")
	step(&w,10);assert(state(&w,e).grounded)
	ecs.character_controller_3d_move(&w,e,{1,0});ecs.character_controller_3d_jump(&w,e)
	ecs.set_enabled(&w,e,false)
	assert(!state(&w,e).jump_requested,"disable clears commands")
	before:=pose(&w,e);step(&w,10);assert(pose(&w,e)==before)
	ecs.set_enabled(&w,e,true);step(&w,2);assert(state(&w,e).grounded)
	copy,ok:=scene.load("tools/character_controller_3d_validation/fixtures/main.scene.json",r);assert(ok)
	other,_:=ecs.find_entity_by_id(&copy,"player")
	assert(ecs.set_runtime_field(&copy,r,other,"CharacterController3D","move_speed",parse(`7`)))
	assert(ecs.apply_value_snapshot(&w,&copy));ecs.destroy(&copy)
	config,_:=ecs.get(&w,e,ecs.CharacterController3D)
	assert(config.move_speed==7 && state(&w,e).grounded,"value reload preserves motor state")
	ecs.character_controller_3d_jump(&w,e)
	t:=pose(&w,e);t.position={0,10,0};ecs.set_transform(&w,e,t)
	step(&w);assert(!state(&w,e).grounded && state(&w,e).velocity[1]<0,"teleport clears pending jump")
	ecs.physics_3d_shutdown(&w);assert(!state(&w,e).active)
	step(&w);assert(state(&w,e).active)
	report:=validation.validate_scene("tools/character_controller_3d_validation/fixtures/invalid.scene.json")
	defer validation.destroy_report(&report)
	assert(!validation.is_valid(&report),"invalid controller diagnosed")
	fmt.println("PASS scene load, disable, reload, teleport, and shutdown")
}
validate_push :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	floor(&w,r)
	crate:=box(&w,r,{2,0.5,0},{1,1,1})
	add(&w,r,crate,"RigidBody3D",`{"type":"dynamic"}`)
	e:=player(&w,r);step(&w,3)
	ecs.character_controller_3d_move(&w,e,{1,0})
	step(&w,120)
	assert(pose(&w,crate).position[0]>3,"push dynamic obstacle")
	assert(pose(&w,e).position[0]<pose(&w,crate).position[0],"remain behind obstacle")
	fmt.println("PASS dynamic-body pushing")
}
main :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	validate_data(&r)
	validate_ground_and_wall(&r)
	validate_jump(&r)
	validate_slopes_steps(&r)
	validate_crouch(&r)
	validate_platform(&r)
	validate_steep(&r)
	validate_jump_edges(&r)
	validate_timing_and_filtering(&r)
	validate_lifecycle(&r)
	validate_push(&r)
	fmt.println("CharacterController3D validation passed")
}
