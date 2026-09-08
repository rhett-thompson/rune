package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "rune:ecs"
import "rune:scene"
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

platform :: proc(w:^ecs.World,r:^ecs.Component_Registry)->ecs.Entity {
	e:=body(w,r)
	add(w,r,e,"Transform",`{"position":[0,100,0]}`)
	add(w,r,e,"BoxCollider2D",`{"size":[200,20],"offset":[0,10]}`)
	add(w,r,e,"RigidBody2D",`{"type":"kinematic","gravity_scale":0}`)
	return e
}
set_velocity :: proc(w:^ecs.World,e:ecs.Entity,v:[2]f32) {
	b,_:=ecs.get_rigid_body_2d(w,e);b.velocity=v;check(ecs.set_rigid_body_2d(w,e,b))
}


check :: proc(ok:bool,message:="check failed") {if !ok {fmt.eprintln(message);os.exit(1)}}
one_way :: proc(w:^ecs.World,r:^ecs.Component_Registry,segment:bool,y:f32)->ecs.Entity {
 p:=platform(w,r)
 t:=pose(w,p);t.position[1]=y;check(ecs.set_transform(w,p,t))
 if segment {
  ecs.remove_component(w,p,"BoxCollider2D")
  add(w,r,p,"SegmentCollider2D",`{"start":[-100,0],"end":[100,0],"one_way":true}`)
 } else {
  c,_:=ecs.get_box_collider_2d(w,p);c.one_way=true;check(ecs.set_box_collider_2d(w,p,c))
 }
 return p
}


obstacle :: proc(w:^ecs.World,r:^ecs.Component_Registry,x,top,width:f32)->ecs.Entity {
 e:=body(w,r);t:=pose(w,e);t.position={x,top,0};ecs.set_transform(w,e,t)
 check(ecs.add(w,r,e,ecs.BoxCollider2D{size={width,100-top},offset={width/2,(100-top)/2}}));return e
}
setup :: proc(w:^ecs.World,r:^ecs.Component_Registry,height:f32)->ecs.Entity {
 e:=player(w,r,-20,100);c:=config();c.step_height=height;check(ecs.set(w,e,c));_=line(w,r,{-300,100},{500,100});step(w,10);return e
}
validate_steps :: proc(r:^ecs.Component_Registry) {
 for enabled in ([]bool{false,true}) {
  w:=ecs.init();defer ecs.destroy(&w)
  e:=setup(&w,r,10 if enabled else 0)
  for i in 0..<3 {_=obstacle(&w,r,f32(i)*30,92-f32(i)*8,30)}
  ecs.character_controller_2d_move(&w,e,1)
  seen:=false
  for i in 0..<80 {step(&w);seen ||= state(&w,e).stepped}
  fmt.println("stairs",enabled,pose(&w,e).position,state(&w,e).grounded,seen)
  if enabled {check(pose(&w,e).position[0]>60 && seen,"climb staircase without jumping")}
  else {check(pose(&w,e).position[0]<0 && !seen,"zero preserves wall blocking")}
 }
}
validate_limits :: proc(r:^ecs.Component_Registry) {
 for kind in ([]string{"tall","roof","crouch","slope","idle","air","sensor","one_way","layer"}) {
  w:=ecs.init();defer ecs.destroy(&w)
  e:=setup(&w,r,10)
  block:=obstacle(&w,r,0,88 if kind=="tall" else 92,200)
  switch kind {
  case "roof","crouch":
   roof:=body(&w,r);add(&w,r,roof,"Transform",`{"position":[0,74,0]}`);add(&w,r,roof,"BoxCollider2D",`{"size":[150,4]}`)
   if kind=="crouch" {c:=config();c.step_height=10;c.crouch_height=10;c.crouch_speed=100;ecs.set(&w,e,c);ecs.character_controller_2d_crouch(&w,e,true)}
  case "slope":
   ecs.remove_component(&w,block,"BoxCollider2D")
   add(&w,r,block,"PolygonCollider2D",`{"vertices":[[0,8],[30,-52],[100,-52],[100,8]]}`)
  case "sensor":check(ecs.set_runtime_field(&w,r,block,"BoxCollider2D","is_sensor",parse(`true`)))
  case "one_way":check(ecs.set_runtime_field(&w,r,block,"BoxCollider2D","one_way",parse(`true`)))
  case "layer":check(ecs.set_entity_layer_mask(&w,block,2))
  case "air":t:=pose(&w,e);t.position[1]=60;ecs.set_transform(&w,e,t)
  }
  if kind!="idle" {ecs.character_controller_2d_move(&w,e,1)}
  seen:=false
  count:=55 if kind!="air" else 8
  for _ in 0..<count {step(&w);seen ||= state(&w,e).stepped}
  fmt.println(kind,pose(&w,e).position,seen)
  switch kind {
  case "tall","roof","slope":check(pose(&w,e).position[0]<5 && !seen,"reject tall, covered or steep obstacle")
  case "crouch":check(pose(&w,e).position[0]>30 && seen && state(&w,e).crouched,"crouched step fits available headroom")
  case "idle","air":check(!seen,"requires grounded input")
  case "sensor","one_way","layer":check(!seen && pose(&w,e).position[0]>30,"filtered/one-way sides cannot manufacture a step")
  }
 }
}
validate_sizes :: proc(r:^ecs.Component_Registry) {
 for direction in ([]f32{-1,1}) {
  for speed in ([]f32{20,100,200}) {
   w:=ecs.init();defer ecs.destroy(&w)
   e:=setup(&w,r,24)
   c:=config();c.step_height=24;c.move_speed=speed;c.acceleration=1600;ecs.set(&w,e,c)
   check(ecs.set_runtime_field(&w,r,e,"CapsuleCollider2D","radius",parse(`10`)))
   check(ecs.set_runtime_field(&w,r,e,"CapsuleCollider2D","height",parse(`64`)))
   check(ecs.set_runtime_field(&w,r,e,"CapsuleCollider2D","radius",parse(`18`)))
   check(ecs.set_runtime_field(&w,r,e,"CapsuleCollider2D","offset",parse(`[0,-32]`)))
   t:=pose(&w,e);t.position[0]=-35*direction;ecs.set_transform(&w,e,t)
   _=obstacle(&w,r,0 if direction>0 else -200,80,200)
   step(&w,10);ecs.character_controller_2d_move(&w,e,direction)
   seen:=false
   for _ in 0..<240 {step(&w);seen ||= state(&w,e).stepped}
   fmt.println("size",direction,speed,pose(&w,e).position,seen)
   check(pose(&w,e).position[0]*direction>35 && seen,"slow/fast movement climbs with full-size capsule in both directions")
  }
 }
}
main :: proc() {
 r:=ecs.init_registry();defer ecs.destroy_registry(&r);check(ecs.register_builtin_components(&r))
 validate_steps(&r)
 validate_limits(&r)
 validate_sizes(&r)
 fmt.println("Step-up 2D validation passed")
}
