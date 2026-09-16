package main

import "core:encoding/json"
import "core:testing"
import "rune:ecs"
import "rune:scene"

@(test)
orientation_component :: proc(t:^testing.T) {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r) && register_planetary_components(&r))
	w,loaded:=scene.load("examples/planetary_3d/scenes/main.scene.json",&r)
	assert(loaded,scene.last_load_error());defer ecs.destroy(&w)
	actor,_:=ecs.find_entity_by_id(&w,"player")
	camera_entity,_:=ecs.find_entity_by_id(&w,"follow_camera")
	actor_config:=orientation_settings(&w,actor)
	camera_config,found:=ecs.get(&w,camera_entity,Orientation_Smoothing)
	authored := Default_Orientation_Smoothing
	authored.max_turn_speed = 4.4
	testing.expect(t,found && actor_config==authored,"scene preserves the authored player smoothing")
	testing.expect(t,camera_config.facing_turn_speed==8 && camera_config.facing_easing_rate==12,"omitted fields retain registered defaults")
	assert(ecs.set_runtime_field(&w,&r,actor,"OrientationSmoothing","max_turn_speed",json.Float(0.6)))
	actor_config=orientation_settings(&w,actor)
	testing.expect(t,actor_config.max_turn_speed==0.6 && orientation_settings(&w,camera_entity).max_turn_speed==2.4,"player tuning is independent of camera tuning")
	actor_up,camera_up:V3={0,1,0},{0,1,0}
	actor_forward,camera_forward:V3={0,0,-1},{0,0,-1}
	actor_speed,camera_speed:f32
	for _ in 0..<60 {
		transport_frame(&actor_up,&actor_forward,&actor_speed,{0,-1,0},1.0/60,actor_config)
		transport_frame(&camera_up,&camera_forward,&camera_speed,{0,-1,0},1.0/60,camera_config)
	}
	testing.expect(t,actor_up[1]>camera_up[1]+0.5,"custom speed changes the rendered alignment rate")
	assert(ecs.set_runtime_field(&w,&r,actor,"OrientationSmoothing","angular_acceleration",json.Float(-1)))
	testing.expect(t,orientation_settings(&w,actor).angular_acceleration==5,"invalid rates use a safe default")
	empty:=ecs.create_entity(&w)
	testing.expect(t,orientation_settings(&w,empty)==Default_Orientation_Smoothing,"missing component keeps default behavior")
}
