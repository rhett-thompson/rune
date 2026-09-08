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

platform :: proc(w:^ecs.World,r:^ecs.Component_Registry)->ecs.Entity {
	e:=body(w,r)
	add(w,r,e,"Transform",`{"position":[0,100,0]}`)
	add(w,r,e,"BoxCollider2D",`{"size":[200,20],"offset":[0,10]}`)
	add(w,r,e,"RigidBody2D",`{"type":"kinematic","gravity_scale":0}`)
	return e
}
set_velocity :: proc(w:^ecs.World,e:ecs.Entity,v:[2]f32) {
	b,_:=ecs.get_rigid_body_2d(w,e);b.velocity=v;assert(ecs.set_rigid_body_2d(w,e,b))
}

validate_carry :: proc(r:^ecs.Component_Registry) {
	for v in ([][2]f32{{60,0},{0,-180},{0,180},{60,90}}) {
		w:=ecs.init();defer ecs.destroy(&w)
		p:=platform(&w,r);e:=player(&w,r,0,100)
		c:=config();c.ground_snap_distance=0;assert(ecs.set(&w,e,c))
		step(&w,10)
		assert(state(&w,e).grounded && state(&w,e).support_entity==p)
		set_velocity(&w,p,v)
		for _ in 0..<60 {
			step(&w)
			d:=pose(&w,e).position-pose(&w,p).position
			if math.abs(d[0])>0.1 || math.abs(d[1])>0.1 || !state(&w,e).grounded {fmt.println("carry",v,d,state(&w,e))}
			assert(math.abs(d[0])<0.1 && math.abs(d[1])<0.1,"carry matches platform displacement exactly")
			assert(state(&w,e).grounded,"descending platform retains support even with snap disabled")
		}
		assert(near(velocity(&w,e)[0],v[0]) && near(velocity(&w,e)[1],v[1]))
		set_velocity(&w,p,-v)
		step(&w,60)
		assert(math.abs(pose(&w,e).position[0])<0.1 && math.abs(pose(&w,e).position[1]-100)<0.1,"direction reversal has no carry lag")
		set_velocity(&w,p,{})
		step(&w,10)
		assert(near(velocity(&w,e)[0],0) && near(velocity(&w,e)[1],0))
	}
	fmt.println("horizontal, ascending, descending, diagonal carry and reversals passed")
}

validate_jump :: proc(r:^ecs.Component_Registry) {
	for v in ([][2]f32{{60,0},{40,-80},{40,280}}) {
		w:=ecs.init();defer ecs.destroy(&w)
		p:=platform(&w,r);e:=player(&w,r,0,100)
		step(&w,10);set_velocity(&w,p,v);step(&w,3)
		ecs.character_controller_2d_jump(&w,e);step(&w)
		assert(near(velocity(&w,e)[0],v[0]) && near(velocity(&w,e)[1],v[1]-config().jump_speed),"jump inherits both velocity axes once")
		assert(!state(&w,e).grounded && state(&w,e).support_entity==0)
		before:=pose(&w,e).position
		step(&w,3)
		assert(!state(&w,e).grounded,"downward elevator must not recapture a departing jump")
		assert(near(velocity(&w,e)[0],v[0]),"air acceleration acts relative to inherited momentum")
		assert(math.abs((pose(&w,e).position[0]-before[0])-v[0]*3/60)<0.02)
		ecs.destroy_entity(&w,p);step(&w)
		assert(near(velocity(&w,e)[0],v[0]),"launched momentum survives source removal")
	}
	fmt.println("horizontal and vertical jump inheritance passed")
}

validate_walkoff :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	p:=platform(&w,r);e:=player(&w,r,0,100)
	step(&w,10);set_velocity(&w,p,{30,0})
	ecs.character_controller_2d_move(&w,e,1)
	left:=false
	for _ in 0..<160 {step(&w);if !state(&w,e).grounded {left=true;break}}
	assert(left && state(&w,e).support_entity==p)
	assert(near(velocity(&w,e)[0],130),"movement is relative to support")
	step(&w,2)
	ecs.character_controller_2d_jump(&w,e);step(&w)
	assert(near(velocity(&w,e)[0],130) && velocity(&w,e)[1]<-200,"coyote jump retains departure momentum")
}

validate_invalidation :: proc(r:^ecs.Component_Registry) {
	for operation in ([]string{"destroy","disable","teleport","shape","layer","body"}) {
		w:=ecs.init();defer ecs.destroy(&w)
		p:=platform(&w,r);e:=player(&w,r,0,100)
		step(&w,10);set_velocity(&w,p,{60,0});step(&w,5)
		assert(state(&w,e).support_entity==p)
		switch operation {
		case "destroy": ecs.destroy_entity(&w,p)
		case "disable": ecs.set_enabled(&w,p,false)
		case "teleport": t:=pose(&w,p);t.position={500,500,0};ecs.set_transform(&w,p,t)
		case "shape": assert(ecs.remove_component(&w,p,"BoxCollider2D"))
		case "layer": assert(ecs.set_entity_layer_mask(&w,p,2))
		case "body": b,_:=ecs.get_rigid_body_2d(&w,p);b.body_type="static";ecs.set_rigid_body_2d(&w,p,b)
		}
		assert(state(&w,e).support_entity==0 && !state(&w,e).grounded && state(&w,e).coyote_remaining==0,operation)
		if operation=="body" {continue} // It can reacquire the now-static platform.
		ecs.character_controller_2d_jump(&w,e);step(&w)
		assert(!state(&w,e).grounded && velocity(&w,e)[1]>0,"invalidated support cannot grant stale jump")
		assert(near(velocity(&w,e)[0],60),"removal preserves existing momentum without adding more carry")
	}
	fmt.println("support destruction, disable, teleport, shape, layer and body changes passed")
}

validate_obstacles :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	p:=platform(&w,r);e:=player(&w,r,0,100)
	line(&w,r,{50,-100},{50,150})
	step(&w,10);set_velocity(&w,p,{60,0});step(&w,60)
	assert(pose(&w,e).position[0]<45.1,"carrying uses collision solving instead of teleporting through walls")
	// A landing transfers the velocity reference without applying carry twice.
	w2:=ecs.init();defer ecs.destroy(&w2)
	p2:=platform(&w2,r);e2:=player(&w2,r,0,60)
	set_velocity(&w2,p2,{20,0});step(&w2,45)
	assert(state(&w2,e2).grounded && state(&w2,e2).support_entity==p2)
	before:=pose(&w2,e2).position[0];step(&w2,30)
	assert(math.abs(pose(&w2,e2).position[0]-before-10)<0.1,"new support supplies carry once")
}


validate_rebuilds :: proc(r:^ecs.Component_Registry) {
	for operation in ([]string{"platform_shape","player_shape","settings","shutdown","incompatible_setup"}) {
		w:=ecs.init();defer ecs.destroy(&w)
		p:=platform(&w,r);e:=player(&w,r,0,100)
		step(&w,10);set_velocity(&w,p,{60,0});step(&w,5)
		switch operation {
		case "platform_shape": assert(ecs.set_runtime_field(&w,r,p,"BoxCollider2D","size.0",parse(`220`)))
		case "player_shape": assert(ecs.set_runtime_field(&w,r,e,"CapsuleCollider2D","radius",parse(`4.5`)))
		case "settings": assert(ecs.set_runtime_field(&w,r,e,"CharacterController2D","move_speed",parse(`120`)))
		case "shutdown": ecs.physics_2d_shutdown(&w)
		case "incompatible_setup":
			add(&w,r,e,"BoxCollider2D",`{"size":[2,2],"offset":[0,-10]}`)
			step(&w)
			assert(!state(&w,e).active)
			assert(ecs.remove_component(&w,e,"BoxCollider2D"))
		}
		step(&w,10)
		assert(state(&w,e).grounded && state(&w,e).support_entity==p)
		assert(near(velocity(&w,e)[0],60),operation)
	}
	w,ok:=scene.load("tools/moving_platform_2d_validation/fixtures/main.scene.json",r)
	assert(ok,scene.last_load_error());defer ecs.destroy(&w)
	e,_:=ecs.find_entity_by_id(&w,"player");p,_:=ecs.find_entity_by_id(&w,"platform")
	step(&w,10);set_velocity(&w,p,{60,0});step(&w,5)
	copy,loaded:=scene.load("tools/moving_platform_2d_validation/fixtures/main.scene.json",r)
	assert(loaded)
	other,_:=ecs.find_entity_by_id(&copy,"platform")
	assert(ecs.set_runtime_field(&copy,r,other,"Transform","position",parse(`[500,500,0]`)))
	assert(ecs.apply_value_snapshot(&w,&copy));ecs.destroy(&copy)
	assert(ecs.is_alive(&w,p) && state(&w,e).support_entity==0 && !state(&w,e).grounded,"value reload clears support even when entity identity survives")
	step(&w)
	assert(!state(&w,e).grounded && velocity(&w,e)[1]>0)
	fmt.println("rebuild and value-reload support lifecycle passed")
}


validate_descending_jump_landing :: proc(r:^ecs.Component_Registry) {
	w:=ecs.init();defer ecs.destroy(&w)
	p:=platform(&w,r);e:=player(&w,r,0,100)
	floor:=line(&w,r,{-200,180},{200,180})
	c:=config();c.max_fall_speed=100;assert(ecs.set(&w,e,c))
	step(&w,10);set_velocity(&w,p,{0,300});step(&w,2)
	ecs.character_controller_2d_jump(&w,e);step(&w)
	assert(velocity(&w,e)[1]>0 && !state(&w,e).grounded,"jump separates upward relative to descending source")
	step(&w,100)
	assert(state(&w,e).grounded && !state(&w,e).jumping && state(&w,e).support_entity==floor,"stationary floor can catch a descending-world-space jump before relative apex")
}

main :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	validate_descending_jump_landing(&r)
	validate_rebuilds(&r)
	validate_carry(&r)
	validate_jump(&r)
	validate_walkoff(&r)
	validate_invalidation(&r)
	validate_obstacles(&r)
	fmt.println("Moving platform 2D validation passed")
}
