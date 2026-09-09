package main

import "core:fmt"
import "core:math"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import rl "vendor:raylib"

bridge: r3d_bridge.Context
player,camera_entity: ecs.Entity
yaw: f32
pitch: f32 = -12
captured: bool

start :: proc(game:^rune.Engine,world:^ecs.World) {
	if !bridge.initialized {
		ok:bool
		bridge,ok = r3d_bridge.init("examples/terrain_3d",rl.GetScreenWidth(),rl.GetScreenHeight())
		if !ok {fmt.eprintln("Could not initialize r3d"); rune.request_exit(game)}
	}
	player,_ = ecs.find_entity_by_id(world,"player")
	camera_entity,_ = ecs.find_entity_by_id(world,"camera")
	update(game,world)
}

controls :: proc(game:^rune.Engine,world:^ecs.World) {
	i := rune.input_state(game)
	if input.pressed(i,"toggle_cursor") {
		captured = !captured
		if captured {rl.DisableCursor()} else {rl.EnableCursor()}
	}
	if captured && !console.is_open(rune.developer_console(game)) {
		yaw += input.axis(i,"look_x")*0.15
		pitch = clamp(pitch-input.axis(i,"look_y")*0.15,-85,85)
	}
}

fixed_update :: proc(game:^rune.Engine,world:^ecs.World) {
	i := rune.input_state(game)
	direction: [2]f32
	if !console.is_open(rune.developer_console(game)) {
		a := yaw*f32(math.PI/180)
		direction = [2]f32{math.sin(a),-math.cos(a)}*input.axis(i,"move_z") + [2]f32{math.cos(a),math.sin(a)}*input.axis(i,"move_x")
		if input.pressed(i,"jump") {ecs.character_controller_3d_jump(world,player)}
	}
	ecs.character_controller_3d_move(world,player,direction,input.is_down(i,"sprint"))
	pose,ok := ecs.get_transform(world,player)
	if ok && (pose.position[1] < -40 || input.pressed(i,"reset")) {
		pose.position = {0,45,55}
		ecs.set_transform(world,player,pose)
	}
}

update :: proc(game:^rune.Engine,world:^ecs.World) {
	pose,found := ecs.get_transform(world,player)
	if !found {return}
	camera,_ := ecs.get_camera_3d(world,camera_entity)
	t,_ := ecs.get_transform(world,camera_entity)
	t.position = pose.position + [3]f32{0,1.6,0}
	a,b := yaw*f32(math.PI/180),pitch*f32(math.PI/180)
	camera.target = t.position + [3]f32{math.sin(a)*math.cos(b),math.sin(b),-math.cos(a)*math.cos(b)}
	ecs.set_transform(world,camera_entity,t)
	ecs.set_camera_3d(world,camera_entity,camera)
}

draw :: proc(game:^rune.Engine,world:^ecs.World) {r3d_bridge.draw_scene(&bridge,world,rune.asset_manager(game))}
draw_ui :: proc(game:^rune.Engine,world:^ecs.World) {
	rl.DrawRectangle(16,16,670,110,{14,24,30,210})
	rl.DrawText("Rune / Highland Walk",30,28,28,rl.RAYWHITE)
	rl.DrawText("WASD move | Shift sprint | Space jump | Escape mouse | R reset",30,65,18,rl.RAYWHITE)
	rl.DrawText("Edit assets/hills.png or hills.terrain.json to reload the landscape",30,93,16,rl.LIGHTGRAY)
	rl.DrawFPS(rl.GetScreenWidth()-100,24)
}
shutdown :: proc(game:^rune.Engine,world:^ecs.World) {r3d_bridge.shutdown(&bridge); rl.EnableCursor()}

main :: proc() {
	game,ok := rune.init("examples/terrain_3d/project.json")
	if !ok {fmt.eprintln("Could not load terrain project"); return}
	defer rune.shutdown(&game)
	rune.register_system(&game,{name="terrain",start=start,ui_update=controls,fixed_update=fixed_update,update=update,draw=draw,draw_ui=draw_ui,on_scene_reloaded=start,shutdown=shutdown})
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
