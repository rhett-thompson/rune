package main

import example_text "../shared/text"

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
console_was_open: bool
show_navigation: bool

set_mouse_capture :: proc(enabled: bool) {
	captured = enabled
	if captured {rl.DisableCursor()} else {rl.EnableCursor()}
}

initialize_mouse :: proc() {
	// Escape belongs to the example's cursor action, not raylib's quit handler.
	rl.SetExitKey(.KEY_NULL)
	console_was_open = false
	set_mouse_capture(true)
}

start :: proc(game:^rune.Engine,world:^ecs.World) {
	if !bridge.initialized {
		ok:bool
		bridge,ok = r3d_bridge.init("examples/terrain_3d",rl.GetScreenWidth(),rl.GetScreenHeight())
		if !ok {fmt.eprintln("Could not initialize r3d"); rune.request_exit(game)}
		initialize_mouse()
	}
	player,_ = ecs.find_entity_by_id(world,"player")
	camera_entity,_ = ecs.find_entity_by_id(world,"camera")
	update(game,world)
}

controls :: proc(game:^rune.Engine,world:^ecs.World) {
	i := rune.input_state(game)
	toggle := input.frame_action(i,"toggle_cursor")
	capture := input.frame_action(i,"capture_cursor")
	console_open := console.is_open(rune.developer_console(game))
	if console_open || console_was_open {
		// The console processes Escape first. Do not also recapture the cursor
		// on the frame that Escape closes it.
		if console_open && captured {set_mouse_capture(false)}
		console_was_open = console_open
		return
	}
	if toggle.pressed {
		set_mouse_capture(!captured)
		return // Ignore mouse warping on the capture frame.
	}
	if rl.IsKeyPressed(.N) {show_navigation=!show_navigation}
	if !captured && capture.pressed {
		set_mouse_capture(true)
		return
	}
	if captured {
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

draw :: proc(game:^rune.Engine,world:^ecs.World) {
	r3d_bridge.draw_scene(&bridge,world,rune.asset_manager(game))
	if !show_navigation {return}
	entity,found:=ecs.find_entity_by_id(world,"navigation");if !found {return}
	mesh,ready:=ecs.navigation_mesh_3d(world,entity);if !ready {return}
	t,_:=ecs.get_transform(world,camera_entity);camera,_:=ecs.get_camera_3d(world,camera_entity)
	rl.BeginMode3D({position=t.position,target=camera.target,up={0,1,0},fovy=camera.fovy,projection=.PERSPECTIVE})
	for triangle in mesh.triangles {
		offset:=[3]f32{0,0.15,0}
		a,b,c:=mesh.vertices[triangle.vertices[0]]+offset,mesh.vertices[triangle.vertices[1]]+offset,mesh.vertices[triangle.vertices[2]]+offset
		rl.DrawLine3D(a,b,{255,220,85,255});rl.DrawLine3D(b,c,{255,220,85,255});rl.DrawLine3D(c,a,{255,220,85,255})
	}
	rl.EndMode3D()
}
draw_ui :: proc(game:^rune.Engine,world:^ecs.World) {
	rl.DrawRectangle(16,16,720,162,{14,24,30,210})
	example_text.draw("Rune / Highland Walk",30,28,28,rl.RAYWHITE)
	example_text.draw("WASD move | Shift sprint | Space jump | Escape mouse | R reset",30,65,18,rl.RAYWHITE)
	example_text.draw("Edit assets/hills.png or hills.terrain.json to reload the landscape",30,93,16,rl.LIGHTGRAY)
	example_text.draw("Mouse look active | Escape releases cursor" if captured else "Mouse released | Click window or press Escape to look around",30,119,16,rl.RAYWHITE)
	example_text.draw("N baked navigation mesh | Re-run navmesh_baker after terrain edits",30,145,16,{255,220,85,255})
	rl.DrawFPS(rl.GetScreenWidth()-100,24)
}
shutdown :: proc(game:^rune.Engine,world:^ecs.World) {r3d_bridge.shutdown(&bridge); set_mouse_capture(false)}
navigation_command :: proc(c:^console.Console,args:string) {
	show_navigation=!show_navigation
	console.info(c,"Baked navigation overlay enabled" if show_navigation else "Baked navigation overlay disabled")
}

main :: proc() {
	game,ok := rune.init("examples/terrain_3d/project.json")
	if !ok {fmt.eprintln("Could not load terrain project"); return}
	defer rune.shutdown(&game)
	console.register(rune.developer_console(&game),"navmesh","Toggle the baked terrain navigation overlay.",navigation_command)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }
	rune.register_system(&game,{name="terrain",start=start,ui_update=controls,fixed_update=fixed_update,update=update,draw=draw,draw_ui=draw_ui,on_scene_reloaded=start,shutdown=shutdown})
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
