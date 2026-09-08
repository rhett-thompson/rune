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

set_crouch_config :: proc(w:^ecs.World,e:ecs.Entity) {
 c:=config();c.crouch_height=10;c.crouch_speed=40;check(ecs.set(w,e,c))
}
effective :: proc(w:^ecs.World,e:ecs.Entity)->ecs.CapsuleCollider2D {c,_:=ecs.get_effective_capsule_collider_2d(w,e);return c}
feet :: proc(w:^ecs.World,e:ecs.Entity)->f32 {
 a,b,r:=ecs.capsule_collider_2d_geometry(effective(w,e),pose(w,e));return max(a[1],b[1])+r
}
roof :: proc(w:^ecs.World,r:^ecs.Component_Registry)->ecs.Entity {
 e:=body(w,r);add(w,r,e,"Transform",`{"position":[0,82,0]}`)
 add(w,r,e,"BoxCollider2D",`{"size":[60,10]}`);return e
}
validate_crouch :: proc(r:^ecs.Component_Registry) {
 for scale in ([][3]f32{{1,1,1},{-1,-1,1},{2,1,1},{1,-2,1}}) {
  w:=ecs.init();defer ecs.destroy(&w)
  e:=player(&w,r,0,100);set_crouch_config(&w,e)
  t:=pose(&w,e);t.scale=scale;check(ecs.set_transform(&w,e,t))
  start_feet:=feet(&w,e);_=line(&w,r,{-400,start_feet},{400,start_feet});step(&w,10)
  before:=feet(&w,e)
  check(ecs.character_controller_2d_crouch(&w,e,true));check(!state(&w,e).crouched,"request waits for physics step")
  step(&w)
  check(state(&w,e).crouched && effective(&w,e).height==10,"crouch changes effective height")
  check(math.abs(feet(&w,e)-before)<0.1,"feet stay planted with reflected/nonuniform scale")
  authored,_:=ecs.get_capsule_collider_2d(&w,e);check(authored.height==20 && authored.offset==([2]f32{0,-10}),"authoring data stays standing size")
  ecs.character_controller_2d_move(&w,e,1);step(&w,30)
  check(near(velocity(&w,e)[0],40),"crouch speed")
  ecs.character_controller_2d_move(&w,e,0);ecs.character_controller_2d_crouch(&w,e,false);step(&w,10)
  check(!state(&w,e).crouched && !state(&w,e).stand_blocked && effective(&w,e).height==20,"clear stand restores geometry")
 }
 fmt.println("latched crouch, speed, circle transition and scaled feet preservation passed")
}
validate_clearance :: proc(r:^ecs.Component_Registry) {
 for kind in ([]string{"box","segment","polygon","sensor","one_way","layer"}) {
  w:=ecs.init();defer ecs.destroy(&w)
  e:=player(&w,r,0,100);set_crouch_config(&w,e);_=line(&w,r,{-400,100},{400,100})
  step(&w,10);ecs.character_controller_2d_crouch(&w,e,true);step(&w)
  ceiling:=roof(&w,r)
  switch kind {
  case "segment":ecs.remove_component(&w,ceiling,"BoxCollider2D");add(&w,r,ceiling,"SegmentCollider2D",`{"start":[-30,5],"end":[30,5]}`)
  case "polygon":ecs.remove_component(&w,ceiling,"BoxCollider2D");add(&w,r,ceiling,"PolygonCollider2D",`{"vertices":[[-30,-5],[30,-5],[30,5],[-30,5]]}`)
  case "sensor":check(ecs.set_runtime_field(&w,r,ceiling,"BoxCollider2D","is_sensor",parse(`true`)))
  case "one_way":check(ecs.set_runtime_field(&w,r,ceiling,"BoxCollider2D","one_way",parse(`true`)))
  case "layer":check(ecs.set_entity_layer_mask(&w,ceiling,2))
  }
  ecs.character_controller_2d_crouch(&w,e,false);step(&w,15)
  blocked:=kind=="box" || kind=="segment" || kind=="polygon"
  check(state(&w,e).stand_blocked==blocked && state(&w,e).crouched==blocked,kind)
  if blocked {
   check(near(feet(&w,e),100),"blocked standing cannot move feet")
   ecs.character_controller_2d_move(&w,e,1);step(&w,90)
   check(!state(&w,e).crouched && !state(&w,e).stand_blocked,"release retries automatically after leaving roof")
  }
 }
 fmt.println("box/segment/polygon clearance, automatic retry, sensors, layers and one-way undersides passed")
}
validate_support :: proc(r:^ecs.Component_Registry) {
 for v in ([][2]f32{{60,0},{0,-90},{0,90}}) {
  w:=ecs.init();defer ecs.destroy(&w)
  p:=one_way(&w,r,false,100);e:=player(&w,r,0,100);set_crouch_config(&w,e)
  c,_:=ecs.get_character_controller_2d(&w,e);c.ground_snap_distance=0;check(ecs.set(&w,e,c))
  step(&w,10);set_velocity(&w,p,v)
  for i in 0..<60 {
   ecs.character_controller_2d_crouch(&w,e,i%12<6);step(&w)
   check(state(&w,e).grounded && state(&w,e).support_entity==p,"posture keeps moving one-way support")
   check(near(velocity(&w,e)[0],v[0]) && near(velocity(&w,e)[1],v[1]),"posture must not add carry twice")
  }
  ecs.character_controller_2d_crouch(&w,e,true);step(&w)
  check(ecs.character_controller_2d_drop_through(&w,e));step(&w)
  check(!state(&w,e).grounded && state(&w,e).drop_entity==p,"crouched drop preserves guard")
  ecs.character_controller_2d_crouch(&w,e,false);step(&w,10)
  check(!state(&w,e).grounded,"standing during drop cannot reacquire source")
 }
 fmt.println("moving one-way carry, repeated resizing, zero snap and drop guards passed")
}
validate_resets :: proc(r:^ecs.Component_Registry) {
 for operation in ([]string{"teleport","scale","collider","disable","remove","shutdown","config"}) {
  w:=ecs.init();defer ecs.destroy(&w)
  e:=player(&w,r,0,100);set_crouch_config(&w,e);_=line(&w,r,{-400,100},{400,100})
  step(&w,10);ecs.character_controller_2d_crouch(&w,e,true);step(&w)
  switch operation {
  case "teleport":t:=pose(&w,e);t.position[0]=100;check(ecs.set_transform(&w,e,t))
  case "scale":t:=pose(&w,e);t.scale[0]=2;check(ecs.set_transform(&w,e,t))
  case "collider":check(ecs.set_runtime_field(&w,r,e,"CapsuleCollider2D","height",parse(`24`)))
  case "disable":ecs.set_enabled(&w,e,false);ecs.set_enabled(&w,e,true)
  case "remove":ecs.remove_component(&w,e,"CharacterController2D")
  case "shutdown":ecs.physics_2d_shutdown(&w)
  case "config":
   _=roof(&w,r)
   check(ecs.set_runtime_field(&w,r,e,"CharacterController2D","move_speed",parse(`120`)))
   step(&w,10);check(state(&w,e).crouched && state(&w,e).stand_blocked,"config reset must check clearance before standing")
   continue
  }
  check(!state(&w,e).crouched && !state(&w,e).crouch_requested,operation)
  step(&w,2);check(effective(&w,e).height>=20,"reset restores authored capsule")
 }
 fmt.println("teleport, scale, collider, activation, removal, shutdown and configuration resets passed")
}
validate_data :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w)
 e:=body(&w,r)
 for text in ([]string{`{"crouch_height":-1}`,`{"crouch_speed":-1}`,`{"crouch_height":true}`}) {check(!ecs.add_component(&w,r,e,"CharacterController2D",parse(text)))}
 c:=config();c.crouch_height=0;c.crouch_speed=0;check(ecs.add(&w,r,e,c),"zero disables crouch; zero speed allowed")
}
validate_reload :: proc(r:^ecs.Component_Registry) {
 w,ok:=scene.load("tools/crouch_2d_validation/fixtures/main.scene.json",r);check(ok);defer ecs.destroy(&w)
 e,_:=ecs.find_entity_by_id(&w,"player")
 step(&w,10);ecs.character_controller_2d_crouch(&w,e,true);step(&w)
 data,serialized:=ecs.runtime_component_json(&w,e,"CapsuleCollider2D");check(serialized)
 c,parsed:=ecs.capsule_collider_2d_from_json(data);check(parsed && c.height==20,"serialization preserves standing geometry")
 same,loaded:=scene.load("tools/crouch_2d_validation/fixtures/main.scene.json",r);check(loaded)
 check(ecs.apply_value_snapshot(&w,&same));ecs.destroy(&same)
 check(state(&w,e).crouched && state(&w,e).crouch_requested,"unchanged value reload preserves posture and request")
 changed,loaded2:=scene.load("tools/crouch_2d_validation/fixtures/main.scene.json",r);check(loaded2)
 other,_:=ecs.find_entity_by_id(&changed,"player")
 check(ecs.set_runtime_field(&changed,r,other,"CapsuleCollider2D","height",parse(`24`)))
 check(ecs.apply_value_snapshot(&w,&changed));ecs.destroy(&changed)
 check(!state(&w,e).crouched && effective(&w,e).height==24,"authored collider reload resets effective geometry")
 fmt.println("standing serialization and unchanged/changed value reload passed")
}
main :: proc() {
 r:=ecs.init_registry();defer ecs.destroy_registry(&r);check(ecs.register_builtin_components(&r))
 validate_reload(&r);validate_data(&r);validate_crouch(&r);validate_clearance(&r);validate_support(&r);validate_resets(&r)
 fmt.println("Crouch 2D validation passed")
}
