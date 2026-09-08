package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "rune:ecs"
import "rune:scene"
import "rune:validation"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}
add :: proc(w: ^ecs.World, r: ^ecs.Component_Registry, e: ecs.Entity, name, text: string) {
	assert(ecs.add_component(w, r, e, name, parse(text)), name)
}
body :: proc(w: ^ecs.World, r: ^ecs.Component_Registry) -> ecs.Entity {
	e := ecs.create_entity(w)
	add(w, r, e, "Transform", `{}`)
	return e
}
near :: proc(a, b: f32) -> bool {return math.abs(a-b) < 0.02}

step :: proc(w:^ecs.World,count:=1) {for _ in 0..<count {ecs.physics_2d_update(w,1.0/60)}}
config :: proc()->ecs.CharacterController2D {
	c:=ecs.default_character_controller_2d()
	c.move_speed,c.acceleration,c.air_acceleration=100,600,300
	c.gravity,c.jump_speed,c.max_fall_speed=600,240,500
	return c
}
player :: proc(w:^ecs.World,r:^ecs.Component_Registry,x,y:f32)->ecs.Entity {
	e:=body(w,r)
	pose,_:=ecs.get_transform(w,e)
	pose.position={x,y,0}
	ecs.set_transform(w,e,pose)
	add(w,r,e,"CapsuleCollider2D",`{"radius":5,"height":20,"offset":[0,-10]}`)
	add(w,r,e,"RigidBody2D",`{}`)
	assert(ecs.add(w,r,e,config()))
	return e
}
line :: proc(w:^ecs.World,r:^ecs.Component_Registry,a,b:[2]f32)->ecs.Entity {
	e:=body(w,r)
	assert(ecs.add(w,r,e,ecs.SegmentCollider2D{start=a,end=b}))
	return e
}
state :: proc(w:^ecs.World,e:ecs.Entity)->ecs.Character_Controller_State_2D {s,_:=ecs.get_character_controller_2d_state(w,e);return s}
pose :: proc(w:^ecs.World,e:ecs.Entity)->ecs.Transform {t,_:=ecs.get_transform(w,e);return t}
velocity :: proc(w:^ecs.World,e:ecs.Entity)->[2]f32 {b,_:=ecs.get_rigid_body_2d(w,e);return b.velocity}

validate_data :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	e:=player(&w,r,0,0)
	data,ok:=ecs.runtime_component_json(&w,e,"CharacterController2D")
	assert(ok && ecs.add_component(&w,r,e,"CharacterController2D",data))
	for bad in ([]string{`{"move_speed":-1}`,`{"acceleration":0}`,`{"gravity":0}`,`{"max_fall_speed":0}`,`{"max_slope_angle":89}`,`{"coyote_time":2}`,`{"jump_buffer_time":-1}`,`{"jump_speed":"fast"}`,`{"grounded":true}`,`{"unknown":0}`}) {
		assert(!ecs.add_component(&w,r,e,"CharacterController2D",parse(bad)),bad)
	}
	c:=config();c.move_speed=math.nan_f32();assert(!ecs.set(&w,e,c))
	assert(!ecs.character_controller_2d_move(&w,e,math.inf_f32(1)))
	assert(ecs.character_controller_2d_move(&w,e,5) && state(&w,e).move_x==1)
	step(&w)
	assert(state(&w,e).active)
	assert(ecs.set_runtime_field(&w,r,e,"CharacterController2D","move_speed",parse(`150`)))
	assert(!state(&w,e).active,"configuration edits reset requests and grace state")
	assert(!ecs.set_runtime_field(&w,r,e,"CharacterController2D","max_slope_angle",parse(`90`)))
	assert(ecs.remove_component(&w,e,"CapsuleCollider2D"))
	step(&w)
	assert(!state(&w,e).active,"incomplete entity does not run motor")
}

validate_flat :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	line(&w,r,{-500,100},{500,100})
	e:=player(&w,r,0,100)
	step(&w,10)
	assert(state(&w,e).grounded,"initial grounding")
	assert(math.abs(pose(&w,e).position[1]-100)<0.1)
	ecs.character_controller_2d_move(&w,e,1)
	step(&w,3)
	assert(velocity(&w,e)[0]>20 && velocity(&w,e)[0]<40,"acceleration is gradual")
	step(&w,20)
	assert(near(velocity(&w,e)[0],100))
	ecs.character_controller_2d_move(&w,e,0)
	step(&w,20)
	assert(near(velocity(&w,e)[0],0) && state(&w,e).grounded)
	start_y:=pose(&w,e).position[1]
	ecs.character_controller_2d_jump(&w,e)
	step(&w)
	assert(velocity(&w,e)[1]<-200 && !state(&w,e).grounded)
	step(&w,5)
	assert(pose(&w,e).position[1]<start_y-15,"jump is not snapped back")
	ecs.character_controller_2d_jump(&w,e)
	step(&w)
	assert(velocity(&w,e)[1]>-200,"no double jump")
	step(&w,80)
	assert(state(&w,e).grounded && math.abs(pose(&w,e).position[1]-100)<0.1)
	fmt.println("flat acceleration, stopping, jump passed")
}

validate_slopes :: proc(r:^ecs.Component_Registry) {
	for direction in ([]f32{1,-1}) {
		w:=ecs.init();defer ecs.destroy(&w)
		line(&w,r,{-200,100},{0,100})
		ramp:=body(&w,r)
		add(&w,r,ramp,"PolygonCollider2D",`{"vertices":[[0,100],[200,40],[200,100]]}`)
		line(&w,r,{200,40},{400,40})
		e:=player(&w,r,-60 if direction>0 else 260,100 if direction>0 else 40)
		step(&w,10)
		ecs.character_controller_2d_move(&w,e,direction)
		grounded_ticks,total_ticks:=0,0
		for _ in 0..<170 {
			step(&w)
			x:=pose(&w,e).position[0]
			if x>15 && x<185 {total_ticks+=1;if state(&w,e).grounded {grounded_ticks+=1}}
		}
		fmt.println("slope",direction,pose(&w,e).position,grounded_ticks,total_ticks)
		assert(total_ticks>80 && grounded_ticks==total_ticks,"continuous support on slopes")
		assert(pose(&w,e).position[0]>200 if direction>0 else pose(&w,e).position[0]<0,"traverse ramp")
		ecs.character_controller_2d_move(&w,e,0)
		step(&w,30)
		assert(state(&w,e).grounded)
	}
	w:=ecs.init();defer ecs.destroy(&w)
	line(&w,r,{-200,100},{0,100})
	line(&w,r,{0,100},{100,-100})
	e:=player(&w,r,-50,100)
	step(&w,10)
	ecs.character_controller_2d_move(&w,e,1)
	step(&w,150)
	fmt.println("steep",pose(&w,e).position)
	assert(pose(&w,e).position[0]<5 && pose(&w,e).position[1]>90,"steep slopes block uphill movement")
}

validate_grace :: proc(r:^ecs.Component_Registry) {
	for late in ([]bool{false,true}) {
		w:=ecs.init();defer ecs.destroy(&w)
		line(&w,r,{-200,100},{0,100})
		e:=player(&w,r,-30,100)
		step(&w,10)
		ecs.character_controller_2d_move(&w,e,1)
		for _ in 0..<100 {step(&w);if !state(&w,e).grounded {break}}
		assert(!state(&w,e).grounded)
		step(&w,9 if late else 2)
		ecs.character_controller_2d_jump(&w,e)
		step(&w)
		assert(velocity(&w,e)[1]>0 if late else velocity(&w,e)[1]<-200,"coyote window")
	}
	for expired in ([]bool{false,true}) {
		w:=ecs.init();defer ecs.destroy(&w)
		line(&w,r,{-200,100},{200,100})
		e:=player(&w,r,0,0)
		if expired {ecs.character_controller_2d_jump(&w,e)}
		for _ in 0..<100 {step(&w);if pose(&w,e).position[1]>87 {break}}
		if !expired {ecs.character_controller_2d_jump(&w,e)}
		jumped:=false
		for _ in 0..<12 {step(&w);if velocity(&w,e)[1]<-200 {jumped=true}}
		assert(jumped != expired,"jump buffer consumed only near landing")
	}
	fmt.println("coyote time and jump buffer passed")
}

validate_snap_and_ceiling :: proc(r:^ecs.Component_Registry) {
	for snap in ([]f32{8,0}) {
		w:=ecs.init();defer ecs.destroy(&w)
		line(&w,r,{-200,100},{0,100})
		line(&w,r,{0,106},{200,106})
		e:=player(&w,r,-30,100)
		c:=config();c.ground_snap_distance=snap;assert(ecs.set(&w,e,c))
		step(&w,10)
		ecs.character_controller_2d_move(&w,e,1)
		air:=0
		for _ in 0..<50 {step(&w);if !state(&w,e).grounded {air+=1}}
		fmt.println("snap",snap,air)
		assert(air==0 if snap>0 else air>0,"snap bridges a short drop")
	}
	w:=ecs.init();defer ecs.destroy(&w)
	line(&w,r,{-200,100},{200,100})
	line(&w,r,{-200,65},{200,65})
	e:=player(&w,r,0,100)
	step(&w,10)
	ecs.character_controller_2d_jump(&w,e)
	for _ in 0..<60 {step(&w);assert(pose(&w,e).position[1]>=84.9,"ceiling blocks capsule")}
	assert(state(&w,e).grounded)
}


validate_lifecycle :: proc(r:^ecs.Component_Registry) {
	w,ok:=scene.load("tools/character_controller_2d_validation/fixtures/main.scene.json",r)
	assert(ok,scene.last_load_error());defer ecs.destroy(&w)
	e,_:=ecs.find_entity_by_id(&w,"player")
	step(&w,10)
	assert(state(&w,e).grounded)
	ecs.character_controller_2d_move(&w,e,1)
	ecs.character_controller_2d_jump(&w,e)
	ecs.set_enabled(&w,e,false)
	assert(!state(&w,e).jump_requested && state(&w,e).move_x==0)
	assert(!ecs.character_controller_2d_jump(&w,e))
	before:=pose(&w,e)
	step(&w,10)
	assert(pose(&w,e)==before)
	ecs.set_enabled(&w,e,true)
	step(&w,10)
	assert(state(&w,e).grounded && near(velocity(&w,e)[0],0))
	copy,loaded:=scene.load("tools/character_controller_2d_validation/fixtures/main.scene.json",r)
	assert(loaded)
	other,_:=ecs.find_entity_by_id(&copy,"player")
	assert(ecs.set_runtime_field(&copy,r,other,"CharacterController2D","move_speed",parse(`250`)))
	assert(ecs.apply_value_snapshot(&w,&copy))
	ecs.destroy(&copy)
	c,_:=ecs.get(&w,e,ecs.CharacterController2D)
	assert(c.move_speed==250 && ecs.is_alive(&w,e))
	step(&w,10)
	assert(state(&w,e).grounded)
	// Teleport clears coyote time and queued jumps instead of granting an air jump.
	ecs.character_controller_2d_jump(&w,e)
	t:=pose(&w,e);t.position={0,-100,0};ecs.set_transform(&w,e,t)
	step(&w)
	assert(!state(&w,e).grounded && velocity(&w,e)[1]>0)
	ecs.physics_2d_shutdown(&w)
	assert(!state(&w,e).active)
	step(&w)
	assert(state(&w,e).active)
	assert(ecs.remove_component(&w,e,"CharacterController2D"))
	assert(len(w.character_controller_states_2d)==0)
	step(&w)
	assert(velocity(&w,e)[1]>20,"normal rigid-body gravity restored on removal")
	ecs.destroy_entity(&w,e)
	assert(len(w.character_controller_states_2d)==0)
	report:=validation.validate_scene("tools/character_controller_2d_validation/fixtures/invalid.scene.json")
	defer validation.destroy_report(&report)
	assert(!validation.is_valid(&report) && len(report.diagnostics)==1)
}

validate_sensors_and_timing :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	floor:=line(&w,r,{-200,100},{200,100})
	e:=player(&w,r,0,80)
	sensor:=body(&w,r)
	add(&w,r,sensor,"BoxCollider2D",`{"size":[100,100],"offset":[0,50],"is_sensor":true}`)
	step(&w)
	assert(!state(&w,e).grounded,"sensor volume cannot support a character")
	entered:=false
	for event in ecs.physics_2d_events(&w) {if event.is_sensor && event.kind==.Begin {entered=true}}
	assert(entered,"controller keeps ordinary sensor events")
	step(&w,20)
	assert(state(&w,e).grounded)
	c:=config();c.coyote_time,c.jump_buffer_time=0,0;c.max_fall_speed=300
	assert(ecs.set(&w,e,c));step(&w,2)
	ecs.character_controller_2d_jump(&w,e)
	ecs.physics_2d_update(&w,0)
	assert(state(&w,e).jump_requested,"pause does not consume request")
	step(&w)
	assert(velocity(&w,e)[1]<-200,"zero grace still accepts a grounded jump edge")
	ecs.destroy_entity(&w,floor)
	step(&w,180)
	assert(near(velocity(&w,e)[1],c.max_fall_speed),"terminal fall speed")
	// Same total fixed time through single and batched calls gives the same motion.
	w2:=ecs.init();defer ecs.destroy(&w2)
	e2:=player(&w2,r,0,0)
	e3:=player(&w,r,500,0)
	ecs.character_controller_2d_move(&w2,e2,1)
	ecs.character_controller_2d_move(&w,e3,1)
	for _ in 0..<10 {ecs.physics_2d_update(&w2,ecs.Physics2D_Fixed_Delta*3);step(&w,3)}
	assert(math.abs(pose(&w2,e2).position[0]-(pose(&w,e3).position[0]-500))<0.01)
	assert(math.abs(pose(&w2,e2).position[1]-pose(&w,e3).position[1])<0.01)
}

main :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	validate_lifecycle(&r)
	validate_sensors_and_timing(&r)
	validate_data(&r)
	validate_flat(&r)
	validate_slopes(&r)
	validate_grace(&r)
	validate_snap_and_ceiling(&r)
	fmt.println("CharacterController2D validation passed")
}

