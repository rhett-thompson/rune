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
	c.dash_speed,c.dash_duration,c.dash_cooldown=180,0.1,0.2
	c.dash_chain_count,c.dash_chain_window=3,0.1
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

flat :: proc(w:^ecs.World,r:^ecs.Component_Registry)->ecs.Entity {
 _=line(w,r,{-500,100},{1000,100});e:=player(w,r,0,100);step(w,10);return e
}
validate_chain :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r);start:=pose(&w,e).position[0]
 check(ecs.character_controller_2d_dash(&w,e,1));check(!state(&w,e).dashing,"request waits for fixed step")
 ecs.physics_2d_update(&w,0);check(state(&w,e).dash_requested,"pause retains dash request")
 step(&w,2);check(state(&w,e).dashing && state(&w,e).dash_chain_index==1)
 check(ecs.character_controller_2d_dash(&w,e,-1));step(&w,4)
 check(!state(&w,e).dashing && state(&w,e).dash_queued && near(pose(&w,e).position[0]-start,18),"one full segment before queued reversal")
 step(&w);check(state(&w,e).dash_started && state(&w,e).dash_chain_index==2 && near(velocity(&w,e)[0],-180),"queued dash starts next step")
 ecs.character_controller_2d_dash(&w,e,-1);ecs.character_controller_2d_dash(&w,e,1);step(&w,5)
 step(&w);check(state(&w,e).dash_chain_index==3 && near(velocity(&w,e)[0],180),"repeated requests coalesce with latest direction")
 ecs.character_controller_2d_dash(&w,e,-1);step(&w,5)
 check(!state(&w,e).dashing && !state(&w,e).dash_queued && state(&w,e).dash_chain_index==0 && near(state(&w,e).dash_cooldown_remaining,0.2),"last dash closes chain and starts cooldown")
 ecs.character_controller_2d_dash(&w,e,1);step(&w);check(!state(&w,e).dash_started,"cooldown press discarded")
 step(&w,12);check(!state(&w,e).dashing,"cooldown does not replay rejected press")
 ecs.character_controller_2d_dash(&w,e,-1);step(&w);check(state(&w,e).dash_started && state(&w,e).dash_chain_index==1,"new chain after cooldown")
 fmt.println("queued chains, redirection, duration, coalescing, limit and cooldown passed")
}
validate_windows :: proc(r:^ecs.Component_Registry) {
 for mode in ([]string{"window","expiry","zero_queued","zero_idle","single"}) {
  w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r);c:=config()
  if mode=="zero_queued" || mode=="zero_idle" {c.dash_chain_window=0}
  if mode=="single" {c.dash_chain_count=1}
  ecs.set(&w,e,c);step(&w,2);ecs.character_controller_2d_dash(&w,e,1);step(&w,2)
  if mode=="zero_queued" || mode=="single" {ecs.character_controller_2d_dash(&w,e,-1)}
  step(&w,4)
  switch mode {
  case "window":step(&w,3);ecs.character_controller_2d_dash(&w,e,-1);step(&w);check(state(&w,e).dash_chain_index==2,"press during window chains")
  case "expiry":step(&w,6);check(state(&w,e).dash_chain_index==0 && near(state(&w,e).dash_cooldown_remaining,0.2),"idle window expires before cooldown begins")
  case "zero_queued":step(&w);check(state(&w,e).dash_started && state(&w,e).dash_chain_index==2,"zero window permits an already queued chain")
  case "zero_idle","single":check(state(&w,e).dash_chain_index==0 && !state(&w,e).dash_queued && state(&w,e).dash_cooldown_remaining>0,mode)
  }
 }
 fmt.println("chain windows, expiry, zero window and single dash passed")
}
validate_permissions_gravity :: proc(r:^ecs.Component_Registry) {
 for ground in ([]bool{false,true}) {
  for allowed in ([]bool{false,true}) {
   w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r) if ground else player(&w,r,0,-100)
   c:=config();c.dash_on_ground=allowed if ground else true;c.dash_in_air=allowed if !ground else true;ecs.set(&w,e,c);step(&w,2)
   ecs.character_controller_2d_dash(&w,e,1);step(&w);check(state(&w,e).dash_started==allowed,"start permission uses actual support")
  }
 }
 for scale in ([]f32{0,0.5,1}) {
  w:=ecs.init();defer ecs.destroy(&w);e:=player(&w,r,0,-100);c:=config();c.dash_gravity_scale=scale;ecs.set(&w,e,c)
  step(&w);set_velocity(&w,e,{0,120});ecs.character_controller_2d_dash(&w,e,1);step(&w)
  check(near(velocity(&w,e)[1],0 if scale==0 else 120+10*scale),"zero cancels vertical jump/fall motion; scaled gravity preserves it")
 }
 fmt.println("ground/air permissions and gravity choices passed")
}
validate_collision :: proc(r:^ecs.Component_Registry) {
 for mode in ([]string{"solid","one_way","sensor","layer","crouch"}) {
  w:=ecs.init();defer ecs.destroy(&w);side:=wall(&w,r,40,mode=="one_way",mode=="sensor");e:=player(&w,r,0,0)
  if mode=="layer" {ecs.set_entity_layer_mask(&w,side,2)}
  c:=config();c.dash_speed=300;c.dash_duration=0.3;ecs.set(&w,e,c)
  if mode=="crouch" {ecs.character_controller_2d_crouch(&w,e,true)}
  ecs.character_controller_2d_dash(&w,e,1);step(&w,10)
  if mode=="solid" || mode=="crouch" {
   check(!state(&w,e).dashing && pose(&w,e).position[0]<25.5,"wall stops dash without tunneling")
   ecs.character_controller_2d_dash(&w,e,-1);step(&w)
   check(state(&w,e).dash_started && velocity(&w,e)[0]<0,"chain can dash away from blocking wall")
  } else {check(state(&w,e).dashing && pose(&w,e).position[0]>45,"filters and one-way sides stay passable")}
 }
 fmt.println("wall interruption, reverse chain, sensors, layers and one-way sides passed")
}
validate_actions :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r)
 ecs.character_controller_2d_dash(&w,e,1);step(&w,2);ecs.character_controller_2d_jump(&w,e);step(&w)
 check(!state(&w,e).dashing && state(&w,e).jumping && state(&w,e).dash_chain_index==0,"ground jump cancels dash chain")
 ecs.character_controller_2d_dash(&w,e,1);ecs.character_controller_2d_release_jump(&w,e);step(&w,20)
 ecs.character_controller_2d_dash(&w,e,1);step(&w)
 check(state(&w,e).dashing && !state(&w,e).jump_cut_available,"dash owns vertical motion after takeoff")
 v:=ecs.init();defer ecs.destroy(&v);side:=wall(&v,r,15);_=side;e2:=player(&v,r,0,0)
 c:=config();c.wall_jump_speed_x,c.wall_jump_speed_y=160,220;ecs.set(&v,e2,c)
 ecs.character_controller_2d_move(&v,e2,1);step(&v,2)
 ecs.character_controller_2d_jump(&v,e2);ecs.character_controller_2d_dash(&v,e2,-1);step(&v)
 check(state(&v,e2).wall_jumped && !state(&v,e2).dashing,"eligible wall jump wins over concurrent dash")
 fmt.println("ground/wall jump priority and release interaction passed")
}
validate_support_drop :: proc(r:^ecs.Component_Registry) {
 for v in ([][2]f32{{40,0},{30,-60},{30,60}}) {
  w:=ecs.init();defer ecs.destroy(&w);p:=body(&w,r)
  add(&w,r,p,"BoxCollider2D",`{"size":[500,20],"offset":[0,110],"one_way":true}`)
  add(&w,r,p,"RigidBody2D",`{"type":"kinematic","gravity_scale":0}`)
  e:=player(&w,r,0,100);step(&w,10);set_velocity(&w,p,v)
  ecs.character_controller_2d_dash(&w,e,1);step(&w)
  check(near(velocity(&w,e)[0],180+v[0]) && near(velocity(&w,e)[1],v[1]),"dash adds supporting platform velocity once")
  check(ecs.character_controller_2d_drop_through(&w,e));ecs.character_controller_2d_dash(&w,e,-1);step(&w)
  check(!state(&w,e).dashing && state(&w,e).drop_entity==p && state(&w,e).dash_chain_index==0,"drop cancels dash and concurrent request")
 }
 fmt.println("moving-platform carry and drop priority passed")
}
validate_data_reset :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w);e:=body(&w,r)
 for invalid in ([]string{`{"dash_speed":-1}`,`{"dash_duration":0}`,`{"dash_duration":1.1}`,`{"dash_cooldown":-1}`,`{"dash_chain_count":0}`,`{"dash_chain_count":1.00000001}`,`{"dash_chain_count":1.5}`,`{"dash_chain_count":33}`,`{"dash_chain_window":1.1}`,`{"dash_in_air":1}`,`{"dash_on_ground":"true"}`,`{"dash_gravity_scale":-1}`}) {
  check(!ecs.add_component(&w,r,e,"CharacterController2D",parse(invalid)),invalid)
 }
 check(ecs.add_component(&w,r,e,"CharacterController2D",parse(`{"dash_speed":200,"dash_chain_count":4,"dash_on_ground":false,"dash_in_air":true}`)))
 data,serialized:=ecs.runtime_component_json(&w,e,"CharacterController2D");check(serialized)
 c,parsed:=ecs.character_controller_2d_from_json(data);check(parsed && c.dash_chain_count==4 && !c.dash_on_ground && c.dash_in_air,"dash config roundtrip")
 for operation in ([]string{"teleport","disable","config","collider","shutdown"}) {
  v:=ecs.init();defer ecs.destroy(&v);p:=flat(&v,r);ecs.character_controller_2d_dash(&v,p,1);step(&v)
  ecs.character_controller_2d_dash(&v,p,-1)
  switch operation {
  case "teleport":t:=pose(&v,p);t.position[0]+=1;ecs.set_transform(&v,p,t)
  case "disable":ecs.set_enabled(&v,p,false);ecs.set_enabled(&v,p,true)
  case "config":check(ecs.set_runtime_field(&v,r,p,"CharacterController2D","dash_chain_count",parse(`2`)))
  case "collider":check(ecs.set_runtime_field(&v,r,p,"CapsuleCollider2D","height",parse(`22`)))
  case "shutdown":ecs.physics_2d_shutdown(&v)
  }
  s:=state(&v,p);check(!s.dashing && !s.dash_requested && !s.dash_queued && s.dash_chain_index==0 && s.dash_cooldown_remaining==0,operation)
 }
 v:=ecs.init();defer ecs.destroy(&v);p:=player(&v,r,0,0);c=ecs.default_character_controller_2d();ecs.set(&v,p,c)
 check(!ecs.character_controller_2d_dash(&v,p,1),"default disables dash")
 c.dash_speed=200;ecs.set(&v,p,c);check(!ecs.character_controller_2d_dash(&v,p,0),"direction must be nonzero")
 fmt.println("dash data, defaults, runtime editing and lifecycle resets passed")
}

validate_transitions :: proc(r:^ecs.Component_Registry) {
 for ground_start in ([]bool{true,false}) {
  w:=ecs.init();defer ecs.destroy(&w)
  _=line(&w,r,{-100,100},{8 if ground_start else 500,100})
  e:=player(&w,r,0,100 if ground_start else 94);c:=config()
  c.dash_on_ground,c.dash_in_air=ground_start,!ground_start;c.dash_gravity_scale=1
  ecs.set(&w,e,c)
  if ground_start {step(&w,10)} else {step(&w);set_velocity(&w,e,{0,100})}
  ecs.character_controller_2d_dash(&w,e,1);step(&w);check(state(&w,e).dashing,"start allowed in original medium")
  ecs.character_controller_2d_dash(&w,e,1);step(&w,5)
  check(state(&w,e).grounded!=ground_start && state(&w,e).dash_queued,"crossing ground/air keeps active segment and queue")
  step(&w);check(!state(&w,e).dashing && state(&w,e).dash_chain_index==0 && state(&w,e).dash_cooldown_remaining>0,"queued segment rechecks permission")
 }
 w:=ecs.init();defer ecs.destroy(&w);p:=body(&w,r)
 add(&w,r,p,"BoxCollider2D",`{"size":[500,20],"offset":[0,110]}`)
 add(&w,r,p,"RigidBody2D",`{"type":"kinematic","gravity_scale":0}`)
 e:=player(&w,r,0,100);step(&w,10);set_velocity(&w,p,{40,-60})
 ecs.character_controller_2d_dash(&w,e,1);step(&w);ecs.destroy_entity(&w,p)
 ecs.character_controller_2d_dash(&w,e,1);step(&w,6)
 check(state(&w,e).dash_chain_index==2 && near(velocity(&w,e)[0],220) && near(velocity(&w,e)[1],-60),"air chain retains departed support momentum without adding twice")
 fmt.println("ground/air transition permissions and source removal passed")
}
validate_reload :: proc(r:^ecs.Component_Registry) {
 w,ok:=scene.load("tools/dash_2d_validation/fixtures/main.scene.json",r);check(ok);defer ecs.destroy(&w)
 e,_:=ecs.find_entity_by_id(&w,"player");ecs.character_controller_2d_dash(&w,e,1);step(&w)
 ecs.character_controller_2d_dash(&w,e,-1);step(&w);before:=state(&w,e)
 same,loaded:=scene.load("tools/dash_2d_validation/fixtures/main.scene.json",r);check(loaded)
 check(ecs.apply_value_snapshot(&w,&same));ecs.destroy(&same)
 after:=state(&w,e);check(after.dashing && after.dash_queued && after.dash_remaining==before.dash_remaining,"unchanged reload preserves ongoing chain")
 changed,loaded2:=scene.load("tools/dash_2d_validation/fixtures/main.scene.json",r);check(loaded2)
 other,_:=ecs.find_entity_by_id(&changed,"player")
 check(ecs.set_runtime_field(&changed,r,other,"CharacterController2D","dash_chain_count",parse(`5`)))
 check(ecs.apply_value_snapshot(&w,&changed));ecs.destroy(&changed)
 after=state(&w,e);check(!after.dashing && !after.dash_queued && after.dash_chain_index==0,"changed config reload clears chain")
 c,_:=ecs.get_character_controller_2d(&w,e);check(c.dash_chain_count==5,"new authoring settings applied")
 fmt.println("unchanged and changed value reload passed")
}

main :: proc() {
 r:=ecs.init_registry();defer ecs.destroy_registry(&r);check(ecs.register_builtin_components(&r))
 validate_reload(&r);validate_transitions(&r);validate_chain(&r);validate_windows(&r);validate_permissions_gravity(&r);validate_collision(&r);validate_actions(&r);validate_support_drop(&r);validate_data_reset(&r)
 fmt.println("Dash 2D validation passed")
}
