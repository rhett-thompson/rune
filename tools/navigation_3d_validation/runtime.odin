package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:navigation"
import rl "vendor:raylib"

frames:int
arrived:bool
validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	game,ok:=rune.init("examples/navigation_3d/project.json");assert(ok)
	defer rune.shutdown(&game)
	assert(rune.register_system(&game,{name="navigation-runtime",start=runtime_start,ui_update=runtime_ui}))
	assert(rune.run_project(&game))
	assert(arrived && frames>5)
	fmt.println("Navigation runtime validation passed: startup asset sync, pause and fixed-step scheduling")
}
runtime_start :: proc(game:^rune.Engine,w:^ecs.World) {
	mesh,ready:=ecs.navigation_mesh_3d(w,entity(w,"navigation"));assert(ready && len(mesh.triangles)>0)
	a:=entity(w,"agent")
	assert(ecs.remove_component(w,a,"CharacterController3D"))
	config,_:=ecs.get(w,a,ecs.NavAgent3D);config.drive_controller=false;config.speed=30
	assert(ecs.set(w,a,config))
	assert(ecs.set_navigation_target_3d(w,a,{7,2,3}))
	rune.set_paused(game,true)
}
runtime_ui :: proc(game:^rune.Engine,w:^ecs.World) {
	frames+=1;assert(frames<240,"navigation must finish in the real engine loop")
	a:=entity(w,"agent")
	pose,_:=ecs.get_transform(w,a)
	if frames<5 {assert(pose.position==([3]f32{-7,0,3}))}
	if frames==5 {rune.set_paused(game,false)}
	state,_:=ecs.get_navigation_state_3d(w,a)
	if state.status==.Arrived {assert(navigation.distance_3d(pose.position,{7,2,3})<0.2);arrived=true;rune.request_exit(game)}
}
