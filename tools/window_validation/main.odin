package main

import "core:fmt"
import "core:math"
import "core:os"
import rune "rune:core"
import "rune:ui"
import rl "vendor:raylib"

fixture :: "build/window-validation.project.json"

write_project :: proc(settings: string) {
	assert(os.write_entire_file(fixture, fmt.tprint(
		`{"name":"Window validation","input":"../examples/clay_ui/input/default.input.json","window":`,settings,"}")) == nil)
}

validate_settings :: proc() {
	write_project(`{}`)
	project, ok := rune.load_project(fixture)
	assert(ok && project.window.high_dpi && !project.window.resizable)
	rune.destroy_project(&project)
	for settings in ([]string{
		`{"mode":"windowed","fullscreen":true,"high_dpi":false,"resizable":true}`,
		`{"mode":"borderless"}`, `{"mode":"fullscreen"}`, `{"fullscreen":true}`,
	}) {
		write_project(settings)
		project, ok = rune.load_project(fixture)
		assert(ok)
		rune.destroy_project(&project)
	}
	for settings in ([]string{`{"mode":"invalid"}`,`{"mode":false}`,`{"mode":""}`,
		`{"high_dpi":"true"}`,`{"resizable":1}`,`{"fullscreen":null}`}) {
		write_project(settings)
		project, ok = rune.load_project(fixture)
		assert(!ok,"invalid window settings rejected before initialization")
	}
}

layout :: proc(ctx: ^ui.Context, controls: ui.Inputs) -> bool {
	assert(ui.begin(ctx,{f32(rl.GetScreenWidth()),f32(rl.GetScreenHeight())},controls,1.0/60))
	ui.panel(ctx,"clip",{layout={sizing={width=ui.fixed(200),height=ui.fixed(100)}},clip={horizontal=true,vertical=true}})
	clicked := ui.button(ctx,"button","DPI test")
	ui.end_panel(ctx)
	assert(ui.finish(ctx))
	return clicked
}

present :: proc(ctx: ^ui.Context) {
	for _ in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		// Oversized content clipped in logical drawing coordinates.
		rl.BeginScissorMode(250,20,40,40)
		rl.DrawRectangle(200,0,200,150,rl.RED)
		rl.EndScissorMode()
		assert(ui.draw(ctx))
		rl.EndDrawing()
	}
}

validate_runtime :: proc() {
	write_project(`{"width":640,"height":480,"resizable":true,"mode":"windowed","fullscreen":true}`)
	game, ok := rune.init(fixture)
	assert(ok)
	defer rune.shutdown(&game)
	assert(rune.window_mode()==.Windowed,"explicit mode overrides legacy fullscreen")
	ctx: ui.Context
	assert(ui.init(&ctx))
	defer ui.destroy(&ctx)
	layout(&ctx,{})
	present(&ctx)
	original := rune.window_metrics()
	position := rl.GetWindowPosition()
	for mode in ([]rune.Window_Mode{.Borderless,.Borderless,.Windowed,.Borderless,.Fullscreen,.Windowed,.Fullscreen,.Borderless,.Windowed}) {
		fmt.println("Checking window mode:", mode)
		assert(rune.set_window_mode(&game,mode))
		layout(&ctx,{})
		present(&ctx)
		metrics := rune.window_metrics()
		assert(rune.window_mode()==mode)
		assert(metrics.framebuffer[0]>0 && metrics.framebuffer[1]>0)
		if mode != .Windowed {
			monitor := rl.GetCurrentMonitor()
			assert(metrics.framebuffer == [2]i32{rl.GetMonitorWidth(monitor),rl.GetMonitorHeight(monitor)},"fullscreen framebuffer fills the current monitor")
		}
		if mode==.Windowed {
			assert(metrics.screen==original.screen && metrics.framebuffer==original.framebuffer,"restore window dimensions without accumulating DPI scale")
			assert(rl.GetWindowPosition()==position,"restore desktop position")
		}
		capture := rl.LoadImageFromScreen()
		sx := f32(capture.width)/f32(metrics.screen[0])
		sy := f32(capture.height)/f32(metrics.screen[1])
		assert(rl.GetImageColor(capture,i32(270*sx),i32(40*sy))==rl.RED,"DPI scissor inside")
		assert(rl.GetImageColor(capture,i32(310*sx),i32(40*sy))==rl.BLACK,"DPI scissor outside")
		rl.UnloadImage(capture)
	}
	// Validate actual raylib mouse conversion against the Clay button bounds.
	box, found := ui.bounds(&ctx,"button")
	assert(found)
	center := rl.Vector2{box.x+box.width/2,box.y+box.height/2}
	scale: rl.Vector2 = {1,1}
	when ODIN_OS == .Windows {scale=rl.GetWindowScaleDPI()}
	rl.SetMousePosition(i32(center.x*scale.x),i32(center.y*scale.y))
	pointer := rl.GetMousePosition()
	assert(math.abs(pointer.x-center.x)<1 && math.abs(pointer.y-center.y)<1,"mouse and drawing coordinates agree")
	assert(!layout(&ctx,{pointer=pointer,pointer_down=true}))
	assert(layout(&ctx,{pointer=pointer}),"release activates scaled button")
	fmt.println("Window runtime: DPI drawing, clipping, pointer, mode transitions and restoration passed",original)
}

validate_startup_mode :: proc(mode: rune.Window_Mode) {
	settings := `{"width":640,"height":480,"high_dpi":false}`
	if mode==.Borderless {settings=`{"width":640,"height":480,"mode":"borderless"}`}
	if mode==.Fullscreen {settings=`{"width":640,"height":480,"fullscreen":true}`}
	write_project(settings)
	game, ok := rune.init(fixture)
	assert(ok)
	defer rune.shutdown(&game)
	assert(rune.window_mode()==mode && rune.window_metrics().high_dpi==(mode!=.Windowed),"startup settings applied")
	assert(rune.set_window_mode(&game,.Windowed))
}

main :: proc() {
	defer os.remove(fixture)
	validate_settings()
	for arg in os.args[1:] {
		switch arg {
		case "--runtime": validate_runtime()
		case "--startup-windowed": validate_startup_mode(.Windowed)
		case "--startup-borderless": validate_startup_mode(.Borderless)
		case "--startup-fullscreen": validate_startup_mode(.Fullscreen)
		}
	}
	fmt.println("Window settings validation passed")
}
