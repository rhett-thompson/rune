package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "rune:ecs"
import "core:os"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	check(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}
add :: proc(w: ^ecs.World, r: ^ecs.Component_Registry, e: ecs.Entity, name, text: string) {
	check(ecs.add_component(w, r, e, name, parse(text)), name)
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
	check(ecs.add(w,r,e,config()))
	return e
}
line :: proc(w:^ecs.World,r:^ecs.Component_Registry,a,b:[2]f32)->ecs.Entity {
	e:=body(w,r)
	check(ecs.add(w,r,e,ecs.SegmentCollider2D{start=a,end=b}))
	return e
}
state :: proc(w:^ecs.World,e:ecs.Entity)->ecs.Character_Controller_State_2D {s,_:=ecs.get_character_controller_2d_state(w,e);return s}
pose :: proc(w:^ecs.World,e:ecs.Entity)->ecs.Transform {t,_:=ecs.get_transform(w,e);return t}
velocity :: proc(w:^ecs.World,e:ecs.Entity)->[2]f32 {b,_:=ecs.get_rigid_body_2d(w,e);return b.velocity}

set_velocity :: proc(w:^ecs.World,e:ecs.Entity,v:[2]f32) {
	b,_:=ecs.get_rigid_body_2d(w,e);b.velocity=v;check(ecs.set_rigid_body_2d(w,e,b))
}


check :: proc(ok:bool,message:="check failed") {if !ok {fmt.eprintln(message);os.exit(1)}}
wall :: proc(w:^ecs.World,r:^ecs.Component_Registry,x:f32,one_way:=false,sensor:=false)->ecs.Entity {
 e:=body(w,r);t:=pose(w,e);t.position={x,0,0};ecs.set_transform(w,e,t)
 check(ecs.add(w,r,e,ecs.BoxCollider2D{size={20,600},one_way=one_way,is_sensor=sensor}))
 return e
}
enable :: proc(w:^ecs.World,e:ecs.Entity) {
 c:=config();c.wall_slide_speed=40;c.wall_jump_speed_x=160;c.wall_jump_speed_y=220;c.wall_jump_lock_time=0.15
 check(ecs.set(w,e,c))
}
validate_slide_jump :: proc(r:^ecs.Component_Registry) {
 for direction in ([]f32{-1,1}) {
  w:=ecs.init();defer ecs.destroy(&w);side:=wall(&w,r,direction*15);e:=player(&w,r,0,0);enable(&w,e)
  ecs.character_controller_2d_move(&w,e,direction);step(&w,12)
  check(state(&w,e).wall_entity==side && state(&w,e).wall_sliding,"pressing toward vertical wall slides")
  check(near(velocity(&w,e)[1],40),"slide speed")
  ecs.character_controller_2d_jump(&w,e);step(&w)
  check(state(&w,e).wall_jumped && near(velocity(&w,e)[0],-direction*160) && near(velocity(&w,e)[1],-220),"wall jump launches away and up")
  ecs.character_controller_2d_jump(&w,e);step(&w,3)
  check(near(velocity(&w,e)[0],-direction*160) && !state(&w,e).wall_jumped,"held inward steering cannot erase push during lock; no repeat in air")
  step(&w,12);check(velocity(&w,e)[0]*direction > -160,"air control resumes")
 }
 fmt.println("left/right slides, wall jumps and steering lock passed")
}
validate_filters :: proc(r:^ecs.Component_Registry) {
 for mode in ([]string{"disabled","slide_only","jump_only","idle","away","sensor","one_way","corner","slope","ground","layers"}) {
  w:=ecs.init();defer ecs.destroy(&w)
  side:=wall(&w,r,15,mode=="one_way",mode=="sensor")
  e:=player(&w,r,0,0);enable(&w,e)
  c,_:=ecs.get_character_controller_2d(&w,e)
  if mode=="disabled" {c.wall_slide_speed,c.wall_jump_speed_x,c.wall_jump_speed_y=0,0,0}
  if mode=="slide_only" {c.wall_jump_speed_x=0}
  if mode=="jump_only" {c.wall_slide_speed=0}
  if mode=="layers" {check(ecs.set_entity_layer_mask(&w,side,2))}
  if mode=="corner" {t:=pose(&w,side);t.position[1]=305;ecs.set_transform(&w,side,t)}
  if mode=="slope" {
   ecs.destroy_entity(&w,side);side=line(&w,r,{5,-5},{45,100})
  }
  if mode=="ground" {_=line(&w,r,{-100,0},{100,0})}
  check(ecs.set(&w,e,c))
  axis:f32=1;if mode=="idle" {axis=0};if mode=="away" {axis=-1}
  ecs.character_controller_2d_move(&w,e,axis);step(&w,2)
  if mode=="slide_only" || mode=="jump_only" {check(state(&w,e).wall_entity!=0,mode)}
  else {check(state(&w,e).wall_entity==0,mode)}
  ecs.character_controller_2d_jump(&w,e);step(&w)
  check(state(&w,e).wall_jumped==(mode=="jump_only"),mode)
 }
 fmt.println("independent opt-ins, input, sensors, one-way sides, corners, slopes and ground passed")
}
validate_edges :: proc(r:^ecs.Component_Registry) {
 for mode in ([]string{"tap","repress","buffer","expired"}) {
  w:=ecs.init();defer ecs.destroy(&w);_=wall(&w,r,15)
  e:=player(&w,r,-1 if mode=="buffer" || mode=="expired" else 0,0);enable(&w,e)
  if mode=="expired" {c,_:=ecs.get_character_controller_2d(&w,e);c.jump_buffer_time=0;ecs.set(&w,e,c)}
  ecs.character_controller_2d_move(&w,e,1)
  ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e)
  if mode=="repress" {ecs.character_controller_2d_jump(&w,e)}
  launched:=false
  for _ in 0..<15 {step(&w);if state(&w,e).wall_jumped {
   launched=true;check(near(velocity(&w,e)[1],-220 if mode=="repress" else -110),mode);break
  }}
  check(launched==(mode!="expired"),mode)
 }
 fmt.println("wall buffered taps, re-press and expiry passed")
}
validate_moving :: proc(r:^ecs.Component_Registry) {
 for v in ([][2]f32{{30,0},{-30,-60},{0,250}}) {
  w:=ecs.init();defer ecs.destroy(&w);side:=wall(&w,r,15);add(&w,r,side,"RigidBody2D",`{"type":"kinematic","gravity_scale":0}`)
  e:=player(&w,r,0,0);enable(&w,e);ecs.character_controller_2d_move(&w,e,1);step(&w,3)
  set_velocity(&w,side,v);ecs.character_controller_2d_jump(&w,e);step(&w)
  check(state(&w,e).wall_jumped && near(velocity(&w,e)[0],v[0]-160) && near(velocity(&w,e)[1],v[1]-220),"moving wall launch")
  ecs.destroy_entity(&w,side);ecs.character_controller_2d_release_jump(&w,e);step(&w)
  check(near(velocity(&w,e)[0],v[0]-160) && near(velocity(&w,e)[1],v[1]-105),"wall contribution survives removal and tap")
 }
 fmt.println("moving wall inheritance and variable jump release passed")
}
validate_reset_data :: proc(r:^ecs.Component_Registry) {
 for mode in ([]string{"teleport","wall_removed","disabled","config"}) {
  w:=ecs.init();defer ecs.destroy(&w);side:=wall(&w,r,15);e:=player(&w,r,0,0);enable(&w,e)
  ecs.character_controller_2d_move(&w,e,1);step(&w,6);check(state(&w,e).wall_sliding)
  switch mode {
  case "teleport":t:=pose(&w,e);t.position[0]=-100;ecs.set_transform(&w,e,t)
  case "wall_removed":ecs.destroy_entity(&w,side)
  case "disabled":ecs.set_enabled(&w,e,false);ecs.set_enabled(&w,e,true)
  case "config":check(ecs.set_runtime_field(&w,r,e,"CharacterController2D","wall_slide_speed",parse(`0`)))
  }
  check(state(&w,e).wall_entity==0 && !state(&w,e).wall_sliding,mode)
 }
 w:=ecs.init();defer ecs.destroy(&w);e:=body(&w,r)
 for invalid in ([]string{`{"wall_slide_speed":-1}`,`{"wall_jump_speed_x":false}`,`{"wall_jump_speed_y":-1}`,`{"wall_jump_lock_time":1.1}`}) {
  check(!ecs.add_component(&w,r,e,"CharacterController2D",parse(invalid)),"invalid wall setting")
 }
 check(ecs.add(&w,r,e,config()))
 for field in ([]string{"wall_slide_speed","wall_jump_speed_x","wall_jump_speed_y","wall_jump_lock_time"}) {
  check(ecs.set_runtime_field(&w,r,e,"CharacterController2D",field,parse(`0.25`)),field)
 }
 data,serialized:=ecs.runtime_component_json(&w,e,"CharacterController2D");check(serialized)
 saved,parsed:=ecs.character_controller_2d_from_json(data)
 check(parsed && saved.wall_slide_speed==0.25 && saved.wall_jump_speed_x==0.25 && saved.wall_jump_speed_y==0.25 && saved.wall_jump_lock_time==0.25,"wall settings serialize and deserialize")
 check(!ecs.set_runtime_field(&w,r,e,"CharacterController2D","wall_jump_lock_time",parse(`2`)))
 after,_:=ecs.get_character_controller_2d(&w,e);check(after==saved,"invalid console edit preserves configuration")
 fmt.println("wall state invalidation and data validation passed")
}

validate_slide_motion :: proc(r:^ecs.Component_Registry) {
 for v in ([]f32{-60,60}) {
  w:=ecs.init();defer ecs.destroy(&w);side:=wall(&w,r,15);add(&w,r,side,"RigidBody2D",`{"type":"kinematic","gravity_scale":0}`)
  e:=player(&w,r,0,0);enable(&w,e);ecs.character_controller_2d_move(&w,e,1);step(&w)
  set_velocity(&w,side,{0,v});set_velocity(&w,e,{0,200});step(&w)
  check(near(velocity(&w,e)[1],v+40) && state(&w,e).wall_sliding,"slide limit is relative to moving wall")
  ecs.character_controller_2d_move(&w,e,0);step(&w)
  check(!state(&w,e).wall_sliding && near(velocity(&w,e)[1],v+50),"release movement restores gravity")
 }
 w:=ecs.init();defer ecs.destroy(&w);_=wall(&w,r,15);e:=player(&w,r,0,0);enable(&w,e)
 c,_:=ecs.get_character_controller_2d(&w,e);c.wall_jump_lock_time=0;ecs.set(&w,e,c)
 ecs.character_controller_2d_move(&w,e,1);ecs.character_controller_2d_jump(&w,e);step(&w,2)
 check(!state(&w,e).wall_sliding && near(velocity(&w,e)[1],-210),"slide does not shorten upward jumps")
 check(state(&w,e).wall_jump_lock_remaining==0 && near(velocity(&w,e)[0],-155),"zero lock permits immediate air steering")
 fmt.println("moving slide limits, upward motion, release and zero lock passed")
}
validate_geometry :: proc(r:^ecs.Component_Registry) {
 for mode in ([]string{"crouch","scale","ceiling"}) {
  w:=ecs.init();defer ecs.destroy(&w);_=wall(&w,r,20 if mode=="scale" else 15)
  e:=player(&w,r,0,0);enable(&w,e)
  if mode=="scale" {t:=pose(&w,e);t.scale={-2,-1,1};ecs.set_transform(&w,e,t)}
  if mode=="crouch" {c,_:=ecs.get_character_controller_2d(&w,e);c.crouch_height=10;ecs.set(&w,e,c);ecs.character_controller_2d_crouch(&w,e,true)}
  if mode=="ceiling" {_=line(&w,r,{-200,-23},{200,-23})}
  ecs.character_controller_2d_move(&w,e,1);step(&w,2);ecs.character_controller_2d_jump(&w,e);step(&w)
  check(state(&w,e).wall_jumped,mode)
  if mode=="ceiling" {step(&w,5);check(pose(&w,e).position[1] > -3.1,"ceiling blocks wall jump physically")}
 }
 fmt.println("effective crouched/reflected geometry and ceiling obstruction passed")
}

main :: proc() {
 r:=ecs.init_registry();defer ecs.destroy_registry(&r);check(ecs.register_builtin_components(&r))
 validate_slide_motion(&r);validate_geometry(&r);validate_slide_jump(&r);validate_filters(&r);validate_edges(&r);validate_moving(&r);validate_reset_data(&r)
 fmt.println("Wall movement 2D validation passed")
}



