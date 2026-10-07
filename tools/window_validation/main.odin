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
	assert(!project.window.vsync && project.window.target_fps == 0,"frame pacing defaults to V-Sync off and no software cap")
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
	for fps in ([]i32{0, 1, 60, 144, 2147483647}) {
		for vsync in ([]bool{false, true}) {
			write_project(fmt.tprint(`{"vsync":`,vsync,`,"target_fps":`,fps,`}`))
			project, ok = rune.load_project(fixture)
			assert(ok && project.window.vsync == vsync && project.window.target_fps == fps,"V-Sync and software cap decode independently")
			rune.destroy_project(&project)
		}
	}
	for settings in ([]string{`{"mode":"invalid"}`,`{"mode":false}`,`{"mode":""}`,
		`{"high_dpi":"true"}`,`{"resizable":1}`,`{"fullscreen":null}`,
		`{"vsync":1}`,`{"vsync":"true"}`,`{"vsync":null}`,
		`{"target_fps":-1}`,`{"target_fps":1.5}`,`{"target_fps":2147483648}`,
		`{"target_fps":true}`,`{"target_fps":"144"}`,`{"target_fps":null}`}) {
		write_project(settings)
		project, ok = rune.load_project(fixture)
		assert(!ok,"invalid window settings rejected before initialization")
	}
	uninitialized: rune.Engine
	assert(!rune.set_vsync(nil,true) && !rune.set_target_fps(nil,144),"nil engine rejected")
	assert(!rune.set_vsync(&uninitialized,true) && !rune.set_target_fps(&uninitialized,144),"frame pacing requires a ready window")
}

frame_pacing_sample :: proc(label: string) -> f64 {
	// Hidden windows and compositor/driver policy can affect swap timing;
	// measurements do not require a particular refresh rate or maximum delay.
	for _ in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		rl.EndDrawing()
	}
	frames :: 12
	started := rl.GetTime()
	for _ in 0..<frames {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		rl.EndDrawing()
	}
	elapsed := rl.GetTime()-started
	if elapsed > 0 {fmt.println(label,"average frame ms:",1000*elapsed/f64(frames),"observed FPS:",f64(frames)/elapsed)}
	return elapsed/f64(frames)
}

validate_frame_pacing_startup :: proc(vsync: bool, target_fps: i32) {
	write_project(fmt.tprint(`{"width":320,"height":240,"high_dpi":false,"vsync":`,vsync,`,"target_fps":`,target_fps,`}`))
	game, ok := rune.init(fixture)
	assert(ok)
	defer rune.shutdown(&game)
	rl.SetWindowState({.WINDOW_HIDDEN})
	// raylib retains flags after CloseWindow; leave later mode tests visible.
	defer rl.ClearWindowState({.WINDOW_HIDDEN})
	assert(rune.window_metrics().vsync == vsync && rl.IsWindowState({.VSYNC_HINT}) == vsync,"startup applies the V-Sync hint")
	assert(game.window.target_fps == target_fps,"startup software cap is independent of V-Sync")
	frame_pacing_sample(fmt.tprint("Startup V-Sync:",vsync,"target FPS:",target_fps))
	assert(!rune.set_vsync(nil,!vsync) && !rune.set_target_fps(nil,72),"nil engine rejected while a window is ready")
	assert(rune.set_vsync(&game,!vsync))
	assert(rune.window_metrics().vsync == !vsync && game.window.target_fps == target_fps,"V-Sync toggle keeps the software cap")
	assert(rune.set_vsync(&game,!vsync),"V-Sync setter is idempotent")
	assert(rune.set_target_fps(&game,72))
	assert(game.window.target_fps == 72 && rune.window_metrics().vsync == !vsync,"software cap setter keeps V-Sync")
	assert(!rune.set_target_fps(&game,-1) && game.window.target_fps == 72,"negative cap rejected without changing the active cap")
	assert(rune.set_vsync(&game,false))
	// Check native pacing as well as the engine's recorded cap. Warmup frames
	// above discard the previous setting's timing. Allow scheduler overshoot
	// without an upper bound, and a broad margin below the nominal interval.
	average := frame_pacing_sample("Runtime V-Sync: false target FPS: 72")
	assert(average >= 0.9/72.0,"software cap delays EndDrawing independently of V-Sync")
	assert(rune.set_target_fps(&game,0) && game.window.target_fps == 0,"zero removes the software cap")
	assert(rune.set_vsync(&game,true) && rune.window_metrics().vsync && game.window.target_fps == 0,"V-Sync does not install a 60 FPS cap")
	assert(rune.set_vsync(&game,false) && !rune.window_metrics().vsync && game.window.target_fps == 0,"disabling V-Sync leaves the software cap clear")
	frame_pacing_sample("Runtime V-Sync: false target FPS: 0")
	assert(game.project.window.vsync == vsync && game.project.window.target_fps == target_fps,"runtime setters preserve project startup settings")
	// Leave the native settings populated at shutdown to exercise resetting
	// stale pacing state when the next engine starts in the same process.
	assert(rune.set_vsync(&game,vsync) && rune.set_target_fps(&game,target_fps))
}

validate_frame_pacing_runtime :: proc() {
	// The first reinitialization changes both enabled/capped settings to
	// disabled/uncapped settings, then covers the other independent pairs.
	validate_frame_pacing_startup(true,144)
	validate_frame_pacing_startup(false,0)
	validate_frame_pacing_startup(true,0)
	validate_frame_pacing_startup(false,144)
	fmt.println("Frame pacing runtime: V-Sync flags, independent caps, runtime setters and startup settings passed")
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
	write_project(`{"width":640,"height":480,"resizable":true,"mode":"windowed","fullscreen":true,"vsync":true,"target_fps":144}`)
	game, ok := rune.init(fixture)
	assert(ok)
	defer rune.shutdown(&game)
	assert(rune.window_mode()==.Windowed,"explicit mode overrides legacy fullscreen")
	assert(rune.window_metrics().vsync && game.window.target_fps == 144,"startup frame pacing applied")
	assert(rune.set_vsync(&game,false) && rune.set_target_fps(&game,90))
	active_vsync := false
	active_target_fps: i32 = 90
	ctx: ui.Context
	assert(ui.init(&ctx))
	defer ui.destroy(&ctx)
	layout(&ctx,{})
	present(&ctx)
	original := rune.window_metrics()
	position := rl.GetWindowPosition()
	for mode, i in ([]rune.Window_Mode{.Borderless,.Borderless,.Windowed,.Borderless,.Fullscreen,.Windowed,.Fullscreen,.Borderless,.Windowed}) {
		if i == 3 {
			active_vsync = true
			active_target_fps = 0
			assert(rune.set_vsync(&game,active_vsync) && rune.set_target_fps(&game,active_target_fps))
		}
		if i == 6 {
			active_vsync = false
			active_target_fps = 90
			assert(rune.set_vsync(&game,active_vsync) && rune.set_target_fps(&game,active_target_fps))
		}
		fmt.println("Checking window mode:", mode)
		assert(rune.set_window_mode(&game,mode))
		layout(&ctx,{})
		present(&ctx)
		metrics := rune.window_metrics()
		assert(rune.window_mode()==mode)
		assert(metrics.vsync == active_vsync && game.window.target_fps == active_target_fps,"window mode changes preserve active frame pacing")
		assert(game.project.window.vsync && game.project.window.target_fps == 144,"window mode changes preserve project startup settings")
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
		case "--runtime":
			validate_frame_pacing_runtime()
			validate_runtime()
		case "--frame-pacing-runtime": validate_frame_pacing_runtime()
		case "--startup-windowed": validate_startup_mode(.Windowed)
		case "--startup-borderless": validate_startup_mode(.Borderless)
		case "--startup-fullscreen": validate_startup_mode(.Fullscreen)
		}
	}
	fmt.println("Window settings validation passed")
}
