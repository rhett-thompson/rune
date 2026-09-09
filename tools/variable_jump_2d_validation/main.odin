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
flat :: proc(w:^ecs.World,r:^ecs.Component_Registry,y:f32)->ecs.Entity {
 _=line(w,r,{-300,100},{300,100});return player(w,r,0,y)
}
validate_height :: proc(r:^ecs.Component_Registry) {
 heights:[3]f32
 for release_at,index in ([]int{-1,0,8}) {
  w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r,100);step(&w,10)
  start:=pose(&w,e).position[1];apex:=start
  ecs.character_controller_2d_jump(&w,e)
  for i in 0..<100 {
   if i==release_at {before:=velocity(&w,e);check(ecs.character_controller_2d_release_jump(&w,e));check(velocity(&w,e)==before,"release is latched")}
   step(&w);apex=min(apex,pose(&w,e).position[1])
  }
  heights[index]=start-apex
 }
 check(heights[1]<heights[2] && heights[2]<heights[0],"tap, partial hold, full hold produce increasing jump heights")
 fmt.println("jump heights (full, tap, partial):",heights)
}
validate_edges :: proc(r:^ecs.Component_Registry) {
 for order in ([]string{"press_release","release_press","press_release_press","idle_release"}) {
  w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r,100);step(&w,10)
  switch order {
  case "press_release":ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e)
  case "release_press":ecs.character_controller_2d_release_jump(&w,e);ecs.character_controller_2d_jump(&w,e)
  case "press_release_press":ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e);ecs.character_controller_2d_jump(&w,e)
  case "idle_release":ecs.character_controller_2d_release_jump(&w,e);step(&w);ecs.character_controller_2d_jump(&w,e)
  }
  step(&w);cut:=order=="press_release"
  check(near(velocity(&w,e)[1],-120 if cut else -240),order)
 }
 w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r,100);step(&w,10)
 ecs.character_controller_2d_jump(&w,e);step(&w,3)
 before:=velocity(&w,e)[1];ecs.character_controller_2d_release_jump(&w,e);step(&w)
 check(near(velocity(&w,e)[1],(before+10)*0.5),"release cuts remaining upward velocity")
 before=velocity(&w,e)[1];ecs.character_controller_2d_release_jump(&w,e);step(&w)
 check(near(velocity(&w,e)[1],before+10),"duplicate releases do not repeatedly cut")
 step(&w,30);before=velocity(&w,e)[1];ecs.character_controller_2d_release_jump(&w,e);step(&w)
 check(!state(&w,e).jump_cut_available,"falling or landed jump cannot be cut again")
 fmt.println("same-step edge order, idle releases and one cut per jump passed")
}
validate_buffer :: proc(r:^ecs.Component_Registry) {
 for repress in ([]bool{false,true}) {
  w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r,94)
  c:=config();c.jump_buffer_time=0.3;ecs.set(&w,e,c);step(&w)
  ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e)
  step(&w);check(state(&w,e).jump_buffer_released,"airborne buffer remembers release")
  if repress {ecs.character_controller_2d_jump(&w,e)}
  launched:=false
  for _ in 0..<30 {step(&w);if state(&w,e).jumping {launched=true;break}}
  check(launched && near(velocity(&w,e)[1],-240 if repress else -120),"buffered tap stays short; newer held press replaces it")
 }
 w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r,-100)
 ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e);step(&w,10)
 check(state(&w,e).jump_buffer_remaining==0 && !state(&w,e).jump_buffer_released,"expired buffer clears its release")
 step(&w,150);ecs.character_controller_2d_jump(&w,e);step(&w)
 check(near(velocity(&w,e)[1],-240),"expired released buffer cannot shorten a later jump")
 fmt.println("buffered taps, re-press, expiry and later jumps passed")
}
validate_platforms :: proc(r:^ecs.Component_Registry) {
 for v in ([][2]f32{{40,0},{40,-80},{40,280}}) {
  w:=ecs.init();defer ecs.destroy(&w);p:=platform(&w,r);e:=player(&w,r,0,100)
  step(&w,10);set_velocity(&w,p,v);step(&w,3)
  ecs.character_controller_2d_jump(&w,e);step(&w)
  before:=velocity(&w,e)
  ecs.destroy_entity(&w,p)
  ecs.character_controller_2d_release_jump(&w,e);step(&w)
  check(near(velocity(&w,e)[1],v[1]+(before[1]+10-v[1])*0.5),"cut preserves frozen platform vertical contribution")
  check(near(velocity(&w,e)[0],v[0]),"cut preserves horizontal carry after source removal")
 }
 w:=ecs.init();defer ecs.destroy(&w);p:=platform(&w,r);e:=player(&w,r,0,100)
 step(&w,10);set_velocity(&w,p,{30,0});ecs.character_controller_2d_move(&w,e,1)
 left:=false
 for _ in 0..<160 {step(&w);if !state(&w,e).grounded {left=true;break}}
 check(left && state(&w,e).coyote_remaining>0)
 ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e);step(&w)
 check(near(velocity(&w,e)[1],-120) && near(velocity(&w,e)[0],130),"coyote tap retains carry")
 fmt.println("static, ascending, descending platforms, source removal and coyote taps passed")
}
validate_data :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w);e:=body(&w,r)
 for value in ([]string{`{"jump_cut_multiplier":-0.1}`,`{"jump_cut_multiplier":1.1}`,`{"jump_cut_multiplier":true}`}) {check(!ecs.add_component(&w,r,e,"CharacterController2D",parse(value)),"invalid cut multiplier")}
 for multiplier in ([]f32{0,1}) {
  v:=ecs.init();e:=flat(&v,r,100);c:=config();c.jump_cut_multiplier=multiplier;check(ecs.set(&v,e,c));step(&v,10)
  ecs.character_controller_2d_jump(&v,e);ecs.character_controller_2d_release_jump(&v,e);step(&v)
  check(near(velocity(&v,e)[1],-240*multiplier),"zero cuts fully; one disables cutting")
  ecs.destroy(&v)
 }
}
validate_lifecycle :: proc(r:^ecs.Component_Registry) {
 for operation in ([]string{"teleport","disable","collider","config","shutdown"}) {
  w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r,100);step(&w,10)
  ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e)
  switch operation {
  case "teleport":t:=pose(&w,e);t.position[0]=10;ecs.set_transform(&w,e,t)
  case "disable":ecs.set_enabled(&w,e,false);ecs.set_enabled(&w,e,true)
  case "collider":check(ecs.set_runtime_field(&w,r,e,"CapsuleCollider2D","radius",parse(`4`)))
  case "config":check(ecs.set_runtime_field(&w,r,e,"CharacterController2D","jump_cut_multiplier",parse(`0.25`)))
  case "shutdown":ecs.physics_2d_shutdown(&w)
  }
  check(!state(&w,e).jump_release_requested && !state(&w,e).jump_buffer_released && !state(&w,e).jump_cut_available,operation)
  step(&w,10);ecs.character_controller_2d_jump(&w,e);step(&w)
  check(near(velocity(&w,e)[1],-240),"reset release cannot leak to next jump")
 }
 w:=ecs.init();defer ecs.destroy(&w);p:=platform(&w,r);e:=player(&w,r,0,100)
 check(ecs.set_runtime_field(&w,r,p,"BoxCollider2D","one_way",parse(`true`)))
 step(&w,10);check(ecs.character_controller_2d_drop_through(&w,e))
 ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e);step(&w)
 check(!state(&w,e).jumping && !state(&w,e).jump_cut_available && !state(&w,e).jump_buffer_released && velocity(&w,e)[1]>0,"drop wins over a released jump")
 fmt.println("release lifecycle resets and drop priority passed")
}
validate_after_apex :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w);e:=flat(&w,r,100);step(&w,10)
 ecs.character_controller_2d_jump(&w,e);step(&w,30)
 before:=velocity(&w,e)[1];check(before>0)
 ecs.character_controller_2d_release_jump(&w,e);step(&w)
 check(near(velocity(&w,e)[1],before+10) && !state(&w,e).jump_cut_applied,"first release after apex leaves falling velocity alone")
}
validate_fall_limit :: proc(r:^ecs.Component_Registry) {
 w:=ecs.init();defer ecs.destroy(&w);p:=platform(&w,r);e:=player(&w,r,0,100)
 c:=config();c.max_fall_speed=100;ecs.set(&w,e,c)
 step(&w,10);set_velocity(&w,p,{0,280});step(&w,2)
 ecs.character_controller_2d_jump(&w,e);ecs.character_controller_2d_release_jump(&w,e);step(&w)
 check(near(velocity(&w,e)[1],100),"cut on descending platform respects terminal speed")
}
main :: proc() {
 r:=ecs.init_registry();defer ecs.destroy_registry(&r);check(ecs.register_builtin_components(&r))
 validate_fall_limit(&r);validate_lifecycle(&r);validate_after_apex(&r);validate_data(&r);validate_height(&r);validate_edges(&r);validate_buffer(&r);validate_platforms(&r)
 fmt.println("Variable jump 2D validation passed")
}
