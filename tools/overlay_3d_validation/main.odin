package main

import "core:fmt"
import "core:os"
import "rune:render"
import "rune:particles"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

failures: int
expect :: proc(ok: bool, message: string) {
	if !ok {fmt.eprintln("FAIL: ",message); failures+=1}
}

main :: proc() {
	layer: render.Overlay3D
	expect(!render.begin_overlay_3d(&layer,{},0,0),"zero-size viewport is rejected without a graphics context")
	render.destroy_overlay_3d(&layer)
	for arg in os.args[1:] {if arg=="--runtime" {runtime_test()}}
	if failures>0 {os.exit(1)}
	fmt.println("3D overlay validation passed (use --runtime for GPU checks).")
}

runtime_test :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(256,256,"Rune 3D overlay validation")
	defer rl.CloseWindow()
	layer,other: render.Overlay3D
	defer render.destroy_overlay_3d(&layer)
	defer render.destroy_overlay_3d(&other)
	camera:=rl.Camera3D{position={},target={0,0,-1},up={0,1,0},fovy=55,projection=.PERSPECTIVE}
	for frame in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		rl.BeginMode3D(camera)
		// Wall fills the view and is much closer than either overlay object.
		rl.DrawCube({0,0,-0.25},2,2,0.1,rl.RED)
		rl.EndMode3D()
		resolution:=i32(128) if frame==2 else i32(256)
		expect(render.begin_overlay_3d(&layer,camera,resolution,resolution),"overlay starts")
		expect(!render.begin_overlay_3d(&other,camera),"nested passes are rejected")
		if frame!=1 {
			rl.DrawCube({0,0,-1},0.5,0.5,0.2,rl.BLUE)
			// Draw the farther object last; overlay depth must keep blue in front.
			rl.DrawCube({0,0,-2},0.8,0.8,0.2,rl.GREEN)
			if frame==2 {
				live:=[2]particles.Particle3D{
					{position={0,0,-2},lifetime=1,start_size=0.3,end_size=0.3,start_color={255,0,0,255},end_color={255,0,0,255}},
					{position={0.34,0,-1},lifetime=1,start_size=0.08,end_size=0.08,start_color={0,230,255,255},end_color={0,230,255,255}},
				}
				before:=live
				render.draw_particles_3d(live[:])
				expect(live==before,"drawing borrows particle state without simulating it")
			}
		}
		render.end_overlay_3d(&layer)
		rl.DrawRectangle(0,0,16,16,rl.YELLOW)
		rlgl.DrawRenderBatchActive()
		capture:=rl.LoadImageFromScreen()
		center:=rl.GetImageColor(capture,128,128)
		corner:=rl.GetImageColor(capture,24,24)
		hud:=rl.GetImageColor(capture,8,8)
		expect(center.r>200 && center.b<100 if frame==1 else center.b>200 && center.r<100,"world cannot obscure overlay; self-occlusion and next-frame clearing work")
		expect(corner.r>200 && corner.b<100,"transparent pixels preserve the world")
		expect(hud.r>200 && hud.g>200 && hud.b<100,"HUD renders above overlay")
		if frame==2 {
			p:=rl.GetImageColor(capture,212,128)
			expect(p.g>150 && p.b>200,"3D particles appear while particles behind model depth remain hidden")
		}
		expect(layer.target.texture.width==resolution && layer.target.texture.height==resolution,"framebuffer resize recreates attachments")
		rl.UnloadImage(capture)
		rl.EndDrawing()
	}
	// Emission masks add a visible halo without presenting their black body.
	rl.BeginDrawing()
	rl.ClearBackground({15,20,25,255})
	rl.DrawRectangle(90,90,76,76,rl.BLUE)
	expect(render.begin_overlay_3d(&other,camera),"emission mask starts")
	rl.DrawCube({0,0,-1},0.4,0.4,0.1,rl.BLACK)
	rl.DrawCube({0,0,-2},0.2,0.2,0.1,rl.WHITE) // hidden by the mask's body depth
	rl.DrawCube({0.4,0,-1},0.025,0.05,0.05,rl.SKYBLUE)
	render.end_overlay_3d(&other,glow={strength=2,radius=8})
	rlgl.DrawRenderBatchActive()
	image:=rl.LoadImageFromScreen()
	center:=rl.GetImageColor(image,128,128)
	fringe:=rl.GetImageColor(image,236,128)
	corner:=rl.GetImageColor(image,24,24)
	expect(other.glow_shader.id!=0,"emission shader compiles")
	expect(center==rl.BLUE,"occluded emitters do not shine through the body")
	expect(fringe.b>25,"emission spreads past the geometry into a halo")
	expect(corner==rl.Color{15,20,25,255},"black emission mask preserves the world")
	rl.UnloadImage(image)
	rl.EndDrawing()
	render.destroy_overlay_3d(&other)
	expect(other.glow_shader.id==0 && other.target.id==0,"glow resources are released")
	expect(!render.begin_overlay_3d(&layer,camera,0,0),"zero-size viewport is rejected")
	render.destroy_overlay_3d(&layer)
	expect(layer.target.id==0 && !layer.active,"GPU resources are released")
	if failures>0 {os.exit(1)}
	fmt.println("3D overlay GPU validation passed: wall isolation, self-occlusion, transparency, HUD order, clearing, resize, lifecycle.")
}
