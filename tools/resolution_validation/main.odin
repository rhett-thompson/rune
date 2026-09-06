package main

import "core:fmt"
import "core:math"
import "core:os"
import "rune:render"
import rl "vendor:raylib"

main :: proc() {
	fit := render.Resolution_Settings{policy=.fit,width=320,height=180}
	assert(render.resolution_rectangle(fit,{1000,800})==rl.Rectangle{0,118.75,1000,562.5})
	integer := fit; integer.policy=.integer
	assert(render.resolution_rectangle(integer,{1000,800})==rl.Rectangle{20,130,960,540})
	assert(render.resolution_rectangle(integer,{160,90})==rl.Rectangle{0,0,160,90})
	point, inside := render.screen_to_canvas(integer,{500,400},{1000,800},{250,200})
	assert(inside && point==[2]f32{160,90})
	_, inside = render.screen_to_canvas(integer,{500,400},{1000,800},{0,0})
	assert(!inside)
	stretch := fit; stretch.policy=.stretch
	assert(render.resolution_rectangle(stretch,{1000,800})==rl.Rectangle{0,0,1000,800})
	assert(!render.resolution_valid({policy=.fit,width=0,height=100}))
	for arg in os.args[1:] {if arg=="--runtime" {runtime_test()}}
	fmt.println("2D resolution: fit, stretch, physical integer scaling, bars and mouse mapping passed")
}

runtime_test :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN,.WINDOW_HIGHDPI})
	rl.InitWindow(500,400,"Resolution validation")
	defer rl.CloseWindow()
	canvas: render.Canvas
	defer render.destroy_canvas(&canvas)
	for policy in ([]render.Resolution_Policy{.fit,.integer,.stretch,.native}) {
		settings := render.Resolution_Settings{policy=policy,width=320,height=180}
		for _ in 0..<3 {
			rl.BeginDrawing()
			assert(render.begin_canvas(&canvas,settings))
			rl.ClearBackground(rl.RED)
			size := render.drawing_size()
			rl.DrawCircleV(size/2,5,rl.GREEN)
			render.end_canvas(&canvas)
			rl.EndDrawing()
		}
		capture := rl.LoadImageFromScreen()
		assert(rl.GetImageColor(capture,capture.width/2,capture.height/2)==rl.GREEN)
		corner := rl.GetImageColor(capture,1,1)
		assert(corner == (rl.BLACK if policy==.fit || policy==.integer else rl.RED))
		rl.UnloadImage(capture)
	}
}
