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
validate_passage :: proc(r:^ecs.Component_Registry) {
 for segment in ([]bool{false,true}) {
  w:=ecs.init();defer ecs.destroy(&w)
  p:=one_way(&w,r,segment,100);e:=player(&w,r,0,145)
  set_velocity(&w,e,{0,-300})
  crossed:=false;landed:=false
  for i in 0..<100 {
   step(&w)
   if pose(&w,e).position[1]<99 {crossed=true}
   if !crossed {
    check(!state(&w,e).grounded,"underside must not ground")
    for event in ecs.physics_2d_events(&w) {check(event.is_sensor || event.kind!=.Begin,"underside must not emit contact Begin")}
   }
   if crossed && state(&w,e).grounded {landed=true;break}
  }
  check(crossed && landed && state(&w,e).support_entity==p,"pass from below then land on top")
  step(&w,120)
  check(math.abs(pose(&w,e).position[1]-100)<0.1,"land on top face")
  check(ecs.character_controller_2d_drop_through(&w,e),"grounded one-way accepts request")
  check(state(&w,e).grounded,"drop is latched until fixed step")
  ecs.character_controller_2d_jump(&w,e)
  step(&w)
  check(!state(&w,e).grounded && !state(&w,e).jumping,"drop wins over jump")
  for _ in 0..<50 {step(&w);check(!state(&w,e).grounded,"cannot recapture dropping character")}
  check(state(&w,e).drop_entity==0 && pose(&w,e).position[1]>150,"guard clears after separation")
 }
 fmt.println("box/segment upward passage, top landing, latched drop and jump priority passed")
}
validate_stacked :: proc(r:^ecs.Component_Registry) {
 for thick in ([]bool{false,true}) {
  w:=ecs.init();defer ecs.destroy(&w)
  p:=one_way(&w,r,false,100);lower:=one_way(&w,r,true,180);e:=player(&w,r,0,100)
  if thick {c,_:=ecs.get_box_collider_2d(&w,p);c.size[1]=70;c.offset[1]=35;check(ecs.set_box_collider_2d(&w,p,c))}
  step(&w,10);check(state(&w,e).support_entity==p)
  c:=config();c.drop_time=0;c.drop_speed=1;c.gravity=1;check(ecs.set(&w,e,c));step(&w,2)
  check(ecs.character_controller_2d_drop_through(&w,e));step(&w,60)
  check(state(&w,e).drop_entity==p && !state(&w,e).grounded,"guard survives expired timer while inside source")
  c.gravity=600;check(ecs.set(&w,e,c));step(&w,100)
  check(state(&w,e).grounded && state(&w,e).support_entity==lower,"drop catches lower one-way platform")
 }
 fmt.println("thick platform guard and lower-platform landing passed")
}
validate_moving :: proc(r:^ecs.Component_Registry) {
 for v in ([][2]f32{{60,0},{0,-180},{0,180},{40,90}}) {
  w:=ecs.init();defer ecs.destroy(&w)
  p:=one_way(&w,r,false,100);e:=player(&w,r,0,100)
  step(&w,10);check(state(&w,e).grounded)
  set_velocity(&w,p,v)
  for _ in 0..<20 {step(&w);check(state(&w,e).grounded,"moving one-way retains rider")}
  check(math.abs(pose(&w,e).position[1]-pose(&w,p).position[1])<0.1)
  check(ecs.character_controller_2d_drop_through(&w,e));step(&w)
  check(!state(&w,e).grounded && velocity(&w,e)[1]>v[1],"drop moves down relative to platform")
  check(near(velocity(&w,e)[0],v[0]),"drop preserves horizontal carry")
  step(&w,20);check(!state(&w,e).grounded,"moving platform cannot recapture drop")
 }
 fmt.println("horizontal, vertical and diagonal moving one-way platforms passed")
}
validate_ordinary :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w)
 _=one_way(&w,r,false,100);e:=body(&w,r)
 add(&w,r,e,"Transform",`{"position":[0,145,0]}`)
 add(&w,r,e,"CircleCollider2D",`{"radius":5}`)
 add(&w,r,e,"RigidBody2D",`{"velocity":[0,-350],"gravity_scale":0.5}`)
 crossed:=false
 for _ in 0..<100 {step(&w);if pose(&w,e).position[1]<90 {crossed=true}}
 b,_:=ecs.get_rigid_body_2d(&w,e)
 check(crossed && b.grounded && math.abs(pose(&w,e).position[1]-95)<0.1,"ordinary dynamic circle obeys one-way collision")
 check(!ecs.character_controller_2d_drop_through(&w,e))
}
validate_data :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w)
 e:=body(&w,r)
 for text in ([]string{`{"one_way":"yes"}`,`{"one_way":true,"is_sensor":true}`}) {check(!ecs.add_component(&w,r,e,"BoxCollider2D",parse(text)),"reject invalid one-way box")}
 check(!ecs.add_component(&w,r,e,"SegmentCollider2D",parse(`{"start":[0,0],"end":[10,2],"one_way":true}`)),"one-way segment must be horizontal")
 for text in ([]string{`{"drop_speed":0}`,`{"drop_time":2}`,`{"drop_time":-1}`}) {check(!ecs.add_component(&w,r,e,"CharacterController2D",parse(text)),"invalid drop settings")}
}
validate_lifecycle :: proc(r:^ecs.Component_Registry) {
 for operation in ([]string{"destroy","disable","teleport","shape","toggle","layer","player_teleport","shutdown"}) {
  w:=ecs.init();defer ecs.destroy(&w)
  p:=one_way(&w,r,false,100);e:=player(&w,r,0,100)
  step(&w,10);check(ecs.character_controller_2d_drop_through(&w,e));step(&w)
  check(state(&w,e).drop_entity==p)
  switch operation {
  case "destroy": ecs.destroy_entity(&w,p)
  case "disable": ecs.set_enabled(&w,p,false)
  case "teleport": t:=pose(&w,p);t.position[1]=200;check(ecs.set_transform(&w,p,t))
  case "shape": check(ecs.set_runtime_field(&w,r,p,"BoxCollider2D","size.0",parse(`220`)))
  case "toggle": check(ecs.set_runtime_field(&w,r,p,"BoxCollider2D","one_way",parse(`false`)))
  case "layer": check(ecs.set_entity_layer_mask(&w,p,2))
  case "player_teleport": t:=pose(&w,e);t.position[1]=50;check(ecs.set_transform(&w,e,t))
  case "shutdown": ecs.physics_2d_shutdown(&w)
  }
  check(state(&w,e).drop_entity==0,operation)
 }
 w,ok:=scene.load("tools/one_way_2d_validation/fixtures/main.scene.json",r)
 check(ok);defer ecs.destroy(&w)
 e,_:=ecs.find_entity_by_id(&w,"player");p,_:=ecs.find_entity_by_id(&w,"platform")
 step(&w,10);check(ecs.character_controller_2d_drop_through(&w,e));step(&w)
 copy,loaded:=scene.load("tools/one_way_2d_validation/fixtures/main.scene.json",r);check(loaded)
 other,_:=ecs.find_entity_by_id(&copy,"platform")
 check(ecs.set_runtime_field(&copy,r,other,"BoxCollider2D","one_way",parse(`false`)))
 check(ecs.apply_value_snapshot(&w,&copy));ecs.destroy(&copy)
 check(state(&w,e).drop_entity==0 && ecs.is_alive(&w,p),"value reload clears guard on surviving entity")
 fmt.println("drop guard invalidation and value reload passed")
}
validate_queries_events :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w)
 p:=one_way(&w,r,false,100);e:=player(&w,r,0,100)
 begins,ends:=0,0
 for _ in 0..<150 {step(&w);for ev in ecs.physics_2d_events(&w) {if !ev.is_sensor {if ev.kind==.Begin {begins+=1} else {ends+=1}}}}
 check(begins==1 && ends==0,"resting platform has one stable Begin event")
 check(ecs.character_controller_2d_drop_through(&w,e));step(&w)
 for ev in ecs.physics_2d_events(&w) {if !ev.is_sensor && ev.kind==.End {ends+=1}}
 check(ends==1,"drop ends admitted contact immediately")
 filter:=ecs.Default_Physics_Query_Filter;filter.ignore=e;filter.include_sensors=false
 hit,found:=ecs.physics_2d_raycast(&w,{0,160},{0,-100},filter)
 check(found && hit.entity==p,"general raycasts remain geometric from below")
 ecs.set_entity_layer_mask(&w,e,2)
 t:=pose(&w,e);t.position[1]=50;ecs.set_transform(&w,e,t);set_velocity(&w,e,{})
 step(&w,60);check(!state(&w,e).grounded && pose(&w,e).position[1]>150,"one-way collision respects layers")
}
validate_selective_drop :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w)
 p:=one_way(&w,r,false,100);lower:=one_way(&w,r,false,150);e:=player(&w,r,0,100)
 step(&w,10);check(ecs.character_controller_2d_drop_through(&w,e));step(&w,100)
 check(state(&w,e).grounded && state(&w,e).support_entity==lower && state(&w,e).support_entity!=p,"drop only ignores source collider")
 check(ecs.set_runtime_field(&w,r,lower,"BoxCollider2D","one_way",parse(`false`)));step(&w,10)
 check(!ecs.character_controller_2d_drop_through(&w,e),"solid support rejects drop")
}
validate_rejump :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w)
 p:=one_way(&w,r,true,100);floor:=line(&w,r,{-100,115},{100,115});e:=player(&w,r,0,100)
 step(&w,10);check(ecs.character_controller_2d_drop_through(&w,e));step(&w,60)
 check(state(&w,e).grounded && state(&w,e).support_entity==floor && state(&w,e).drop_entity==p,"low floor catches drop before capsule clears source")
 ecs.character_controller_2d_jump(&w,e);step(&w,120)
 check(state(&w,e).grounded && state(&w,e).support_entity==p && state(&w,e).drop_entity==0,"later jump clears guard above source and can land again")
}
validate_below :: proc(r:^ecs.Component_Registry) {
 for y in ([]f32{105,145}) {
  w:=ecs.init();defer ecs.destroy(&w)
  _=one_way(&w,r,false,100);e:=player(&w,r,0,y)
  set_velocity(&w,e,{0,-30})
  for _ in 0..<45 {step(&w);check(!state(&w,e).grounded,"insufficient upward passage or spawn inside cannot acquire top")}
 }
}
main :: proc() {
 r:=ecs.init_registry();defer ecs.destroy_registry(&r)
 check(ecs.register_builtin_components(&r))
 validate_rejump(&r)
 validate_below(&r)
 validate_lifecycle(&r)
 validate_queries_events(&r)
 validate_selective_drop(&r)
 validate_data(&r)
 validate_passage(&r)
 validate_stacked(&r)
 validate_moving(&r)
 validate_ordinary(&r)
 fmt.println("One-way platform 2D validation passed")
}
