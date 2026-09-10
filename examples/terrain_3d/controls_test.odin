package main

import "core:math"
import "core:testing"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:scene"
import rl "vendor:raylib"

@(test)
mouse_capture_and_look :: proc(t: ^testing.T) {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,240,"Terrain controls validation")
	defer rl.CloseWindow()
	defer set_mouse_capture(false)
	i,ok := input.load("examples/terrain_3d/input/default.input.json")
	assert(ok)
	game := rune.Engine{input=i,console=console.init()}
	defer input.destroy(&game.input)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w,loaded := scene.load("examples/terrain_3d/scenes/main.scene.json",&r)
	assert(loaded)
	defer ecs.destroy(&w)
	player,_=ecs.find_entity_by_id(&w,"player")
	camera_entity,_=ecs.find_entity_by_id(&w,"camera")
	yaw=0; pitch=-12
	initialize_mouse()
	testing.expect(t,captured && rl.IsCursorHidden(),"mouse look starts captured")
	game.input.axes["look_x"]=20
	game.input.axes["look_y"]=-10
	controls(&game,&w); update(&game,&w)
	camera,_ := ecs.get_camera_3d(&w,camera_entity)
	testing.expect(t,math.abs(yaw-3)<0.001 && math.abs(pitch+10.5)<0.001,"mouse deltas change yaw and pitch")
	pose,_ := ecs.get_transform(&w,camera_entity)
	testing.expect(t,camera.target[0]-pose.position[0]>0.04 && camera.target[2]-pose.position[2]< -0.9,"look changes the camera direction")
	assert(input.inject_action(&game.input,"toggle_cursor",true))
	controls(&game,&w)
	testing.expect(t,!captured && !rl.IsCursorHidden(),"Escape releases the cursor")
	controls(&game,&w)
	testing.expect(t,!captured && math.abs(yaw-3)<0.001,"held Escape does not toggle twice; released mouse cannot look")
	assert(input.clear_injected_action(&game.input,"toggle_cursor"))
	assert(input.inject_action(&game.input,"capture_cursor",true))
	controls(&game,&w)
	testing.expect(t,captured && math.abs(yaw-3)<0.001,"click recaptures without applying the warp delta")
	assert(input.clear_injected_action(&game.input,"capture_cursor"))
	game.console.is_open=true
	controls(&game,&w)
	testing.expect(t,!captured,"console releases the mouse")
	game.console.is_open=false
	assert(input.inject_action(&game.input,"toggle_cursor",true))
	controls(&game,&w)
	testing.expect(t,!captured,"Escape closing the console does not recapture")
	controls(&game,&w)
	testing.expect(t,!captured,"console Escape edge is consumed once")
	assert(input.inject_action(&game.input,"toggle_cursor",false)); controls(&game,&w)
	assert(input.inject_action(&game.input,"toggle_cursor",true)); controls(&game,&w)
	testing.expect(t,captured,"a fresh Escape press recaptures")
}
