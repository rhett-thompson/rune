package main

import "core:fmt"
import "core:math"
import "core:os"
import rune "rune:core"
import "rune:ui"
import rl "vendor:raylib"

when ODIN_OS == .Windows {
	// Reuse raylib's User32 linkage; importing User32 separately can resolve
	// CloseWindow to Win32's function instead of raylib's implementation.
	@(default_calling_convention = "system")
	foreign {
		GetWindowLongW :: proc(handle: rawptr, index: i32) -> i32 ---
	}
}

fixture :: "build/window-validation.project.json"

validate_borderless_window_flags :: proc() {
	assert(rune.window_mode() == .Borderless)
	assert(rl.IsWindowState({.WINDOW_UNDECORATED}),"borderless removes desktop window decorations")
	assert(!rl.IsWindowFullscreen() && !rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}),"borderless uses an ordinary desktop window without raylib fullscreen monitor ownership")
	assert(!rl.IsWindowState({.WINDOW_TOPMOST}),"borderless does not force the window above other applications")
	when ODIN_OS == .Windows {
		assert(GetWindowLongW(rl.GetWindowHandle(), -16) & 0x00c40000 == 0,"borderless native window has no caption or resizing frame")
		assert(GetWindowLongW(rl.GetWindowHandle(), -20) & 0x8 == 0,"borderless native window is not WS_EX_TOPMOST")
	}
}

validate_borderless_native_state :: proc(game: ^rune.Engine) {
	validate_borderless_window_flags()
	before := rune.window_metrics()
	position := rl.GetWindowPosition()
	target_fps := game.window.target_fps
	assert(rune.set_window_mode(game, .Borderless),"setting borderless repeatedly succeeds")
	after := rune.window_metrics()
	assert(after.screen == before.screen && after.framebuffer == before.framebuffer,"setting borderless repeatedly keeps the dimensions")
	assert(after.dpi == before.dpi && after.high_dpi == before.high_dpi,"setting borderless repeatedly keeps DPI settings")
	assert(after.resizable == before.resizable && after.vsync == before.vsync,"setting borderless repeatedly keeps resize and V-Sync settings")
	assert(game.window.target_fps == target_fps,"setting borderless repeatedly keeps the software frame cap")
	assert(rl.GetWindowPosition() == position,"setting borderless repeatedly keeps the desktop position")
	validate_borderless_window_flags()
}

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

present :: proc(ctx: ^ui.Context, game: ^rune.Engine = nil) {
	for _ in 0..<3 {
		if game != nil {rune.begin_frame(game)}
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		// Oversized content clipped in logical drawing coordinates.
		rl.BeginScissorMode(250,20,40,40)
		rl.DrawRectangle(200,0,200,150,rl.RED)
		rl.EndScissorMode()
		assert(ui.draw(ctx))
		rl.EndDrawing()
		// X11 window-manager resize events arrive asynchronously. Give each
		// presentation a desktop event turn even when V-Sync and the cap are off.
		rl.WaitTime(0.01)
	}
}

wait_for_window_size :: proc(ctx: ^ui.Context, expected_screen, expected_framebuffer: [2]i32, game: ^rune.Engine = nil) {
	// Desktop compositors can deliver resize events several frames after a
	// request. Keep the assertion bounded while waiting for the native result.
	for _ in 0..<30 {
		metrics := rune.window_metrics()
		if metrics.screen == expected_screen && metrics.framebuffer == expected_framebuffer {
			// The callback can run in EndDrawing after that frame was rendered.
			// Present at the settled dimensions before checking captured pixels.
			layout(ctx,{})
			present(ctx,game)
			return
		}
		present(ctx,game)
	}
}

validate_restored_position :: proc(expected: rl.Vector2) {
	actual := rl.GetWindowPosition()
	when ODIN_OS == .Linux {
		// X11 WMs can add a decoration-frame offset to a restored position.
		// This also occurs with raylib's original borderless implementation.
		assert(math.abs(actual.x-expected.x) <= 32 && math.abs(actual.y-expected.y) <= 64,"restore desktop position within the window-manager decoration frame")
	} else {
		assert(actual == expected,"restore desktop position")
	}
}

validate_maximized_roundtrip :: proc(game: ^rune.Engine, ctx: ^ui.Context) {
	original := rune.window_metrics()
	position := rl.GetWindowPosition()
	rl.MaximizeWindow()
	previous := original
	stable_frames := 0
	for _ in 0..<30 {
		present(ctx,game)
		metrics := rune.window_metrics()
		if metrics.screen == previous.screen && metrics.framebuffer == previous.framebuffer {stable_frames += 1} else {stable_frames = 0}
		if stable_frames >= 3 && metrics.framebuffer != original.framebuffer {break}
		previous = metrics
	}
	if !rl.IsWindowMaximized() || rune.window_metrics().framebuffer == original.framebuffer {
		rl.RestoreWindow()
		wait_for_window_size(ctx,original.screen,original.framebuffer,game)
		fmt.println("Maximized window roundtrip skipped: desktop backend did not maximize the window")
		return
	}
	maximized := rune.window_metrics()
	assert(rune.set_window_mode(game, .Borderless))
	present(ctx,game)
	validate_borderless_native_state(game)
	assert(rune.set_window_mode(game, .Windowed))
	wait_for_window_size(ctx,maximized.screen,maximized.framebuffer,game)
	assert(rl.IsWindowMaximized(),"leaving borderless restores a maximized window")
	restored := rune.window_metrics()
	assert(restored.screen == maximized.screen && restored.framebuffer == maximized.framebuffer,fmt.tprint("maximized roundtrip restores the desktop dimensions: ",restored," expected: ",maximized))
	assert(restored.dpi == maximized.dpi && restored.vsync == maximized.vsync,"maximized roundtrip preserves DPI and V-Sync")
	rl.RestoreWindow()
	wait_for_window_size(ctx,original.screen,original.framebuffer,game)
	restored = rune.window_metrics()
	assert(restored.screen == original.screen && restored.framebuffer == original.framebuffer,"restoring after a maximized roundtrip keeps normal dimensions")
	validate_restored_position(position)
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
	windowed_position := position
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
		if mode == .Windowed {
			wait_for_window_size(&ctx,original.screen,original.framebuffer)
		} else {
			when ODIN_OS != .Darwin {
				monitor := rl.GetCurrentMonitor()
				framebuffer := [2]i32{rl.GetMonitorWidth(monitor),rl.GetMonitorHeight(monitor)}
				dpi := rl.GetWindowScaleDPI()
				screen := [2]i32{i32(f32(framebuffer[0])/dpi.x),i32(f32(framebuffer[1])/dpi.y)}
				wait_for_window_size(&ctx,screen,framebuffer)
			}
		}
		metrics := rune.window_metrics()
		fmt.println("Window mode metrics:",metrics,"saved native size:",game.window.size,"position:",rl.GetWindowPosition())
		assert(rune.window_mode()==mode)
		if mode == .Borderless {validate_borderless_native_state(&game)}
		assert(metrics.vsync == active_vsync && game.window.target_fps == active_target_fps,"window mode changes preserve active frame pacing")
		assert(game.project.window.vsync && game.project.window.target_fps == 144,"window mode changes preserve project startup settings")
		assert(metrics.framebuffer[0]>0 && metrics.framebuffer[1]>0)
		if mode != .Windowed {
			monitor := rl.GetCurrentMonitor()
			monitor_size := [2]i32{rl.GetMonitorWidth(monitor),rl.GetMonitorHeight(monitor)}
			when ODIN_OS == .Darwin {
				if mode == .Borderless {assert(metrics.screen == monitor_size,"borderless fills the monitor in Cocoa points")}
			} else {
				assert(metrics.framebuffer == monitor_size,fmt.tprint("fullscreen framebuffer fills the current monitor: ",metrics," monitor: ",monitor_size))
			}
		}
		if mode==.Windowed {
			assert(metrics.screen==original.screen && metrics.framebuffer==original.framebuffer,fmt.tprint("restore window dimensions without accumulating DPI scale: ",metrics," original: ",original))
			assert(metrics.dpi==original.dpi && metrics.high_dpi==original.high_dpi,"restore window DPI settings")
			assert(metrics.resizable==original.resizable && !rl.IsWindowState({.WINDOW_UNDECORATED}),"restore window decorations and resize settings")
			validate_restored_position(windowed_position)
			windowed_position = rl.GetWindowPosition()
		}
		inside, outside := false, false
		for _ in 0..<30 {
			capture := rl.LoadImageFromScreen()
			sx := f32(capture.width)/f32(metrics.screen[0])
			sy := f32(capture.height)/f32(metrics.screen[1])
			inside = rl.GetImageColor(capture,i32(270*sx),i32(40*sy)) == rl.RED
			outside = rl.GetImageColor(capture,i32(310*sx),i32(40*sy)) == rl.BLACK
			rl.UnloadImage(capture)
			if inside && outside {break}
			// A compositor can recreate the swap buffers after a monitor-mode
			// change even when the reported framebuffer dimensions stay equal.
			present(&ctx,&game)
		}
		assert(inside,"DPI scissor inside")
		assert(outside,"DPI scissor outside")
	}
	// Queue an opposite resize before the first resize has reached X11's
	// framebuffer callback. The final request must still restore the window.
	assert(rune.set_window_mode(&game,.Borderless))
	assert(rune.set_window_mode(&game,.Windowed))
	wait_for_window_size(&ctx,original.screen,original.framebuffer)
	metrics := rune.window_metrics()
	assert(metrics.screen == original.screen && metrics.framebuffer == original.framebuffer,"rapid mode changes preserve the final requested window size")
	validate_maximized_roundtrip(&game,&ctx)
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
	if mode == .Borderless {validate_borderless_native_state(&game)}
	assert(rune.set_window_mode(&game,.Windowed))
}

validate_borderless_shutdown_reset :: proc() {
	write_project(`{"width":640,"height":480,"mode":"borderless"}`)
	game, ok := rune.init(fixture)
	assert(ok)
	defer rune.shutdown(&game)
	validate_borderless_native_state(&game)
	rune.shutdown(&game)
	assert(!rl.IsWindowReady())
	write_project(`{"width":640,"height":480,"mode":"windowed"}`)
	game, ok = rune.init(fixture)
	assert(ok)
	assert(rune.window_mode() == .Windowed && !rl.IsWindowFullscreen(),"a new engine starts windowed after closing in borderless")
	assert(!rl.IsWindowState({.WINDOW_UNDECORATED}) && !rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}),"a new engine clears retained borderless window flags")
	assert(!rl.IsWindowState({.WINDOW_TOPMOST}),"a new windowed engine remains below other focused applications")
	fmt.println("Window startup: closing in borderless does not affect the next windowed engine")
}

main :: proc() {
	defer os.remove(fixture)
	validate_settings()
	for arg in os.args[1:] {
		switch arg {
		case "--runtime":
			validate_frame_pacing_runtime()
			validate_borderless_shutdown_reset()
			validate_runtime()
		case "--frame-pacing-runtime": validate_frame_pacing_runtime()
		case "--startup-windowed": validate_startup_mode(.Windowed)
		case "--startup-borderless": validate_startup_mode(.Borderless)
		case "--startup-fullscreen": validate_startup_mode(.Fullscreen)
		}
	}
	fmt.println("Window settings validation passed")
}
