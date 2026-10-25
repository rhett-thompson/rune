package core

import "rune:console"
import rl "vendor:raylib"

Window_Mode :: enum {Windowed, Borderless, Fullscreen}

Window_State :: struct {
	// Startup remains hidden through the first presented frame when requested.
	show_pending: bool,
	// Persistent visibility is independent of the one-time startup reveal.
	hidden: bool,
	// Preserve the application's minimized-window event policy across hiding.
	hidden_always_run: bool,
	// Requested mode while startup or persistent hiding defers native changes.
	startup_mode: Window_Mode,
	// Native client size and desktop position, retained across mode changes.
	size: [2]i32,
	position: rl.Vector2,
	maximized: bool,
	saved: bool,
	geometry_pending_until: f64,
	pending_maximize: bool,
	// Requested runtime cap; fast stepping can temporarily leave pacing uncapped.
	// project.window retains the startup settings.
	target_fps: i32,
	step_uncapped: bool,
}

Window_Metrics :: struct {
	mode: string,
	screen: [2]i32,
	framebuffer: [2]i32,
	dpi: [2]f32,
	high_dpi: bool,
	resizable: bool,
	vsync: bool,
	// mode and dimensions describe native state; requested_mode includes a
	// deferred mode when window_metrics receives an Engine.
	requested_mode: string,
	hidden: bool,
}

parse_window_mode :: proc(name: string) -> (Window_Mode, bool) {
	switch name {
	case "windowed": return .Windowed, true
	case "borderless": return .Borderless, true
	case "fullscreen": return .Fullscreen, true
	}
	return .Windowed, false
}

window_mode_name :: proc(mode: Window_Mode) -> string {
	switch mode {
	case .Windowed: return "windowed"
	case .Borderless: return "borderless"
	case .Fullscreen: return "fullscreen"
	}
	return ""
}

// With an engine, include a mode queued until the window is revealed.
// Without one, report the actual native window state.
window_mode :: proc(engine: ^Engine = nil) -> Window_Mode {
	if engine != nil && (engine.window.show_pending || engine.window.hidden) {return engine.window.startup_mode}
	if rl.IsWindowFullscreen() {return .Fullscreen}
	if rl.IsWindowState({.WINDOW_UNDECORATED}) || rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {return .Borderless}
	return .Windowed
}

// Call between frames or during update, before BeginDrawing. Idempotent.
// Changes runtime state only; project.json remains the startup configuration.
set_window_mode :: proc(engine: ^Engine, mode: Window_Mode) -> bool {
	if engine == nil || !rl.IsWindowReady() || window_mode_name(mode) == "" {return false}
	if engine.window.hidden {
		// Native mode changes (including maximize/monitor attachment) can show
		// the surface. Preserve all requests until explicitly revealed.
		engine.window.startup_mode = mode
		return true
	}
	if engine.window.show_pending && mode == .Fullscreen {
		engine.window.startup_mode = mode
		// GLFW's Win32 monitor attachment shows even a hidden window. Wait
		// until a complete frame has been painted before entering fullscreen.
		return true
	}
	return apply_window_mode(engine, mode)
}

@(private)
apply_window_mode :: proc(engine: ^Engine, mode: Window_Mode, restore_maximized: bool = true) -> bool {
	previous := window_mode()
	if previous == mode {
		if engine.window.show_pending {engine.window.startup_mode = mode}
		return true
	}
	monitor := rl.GetCurrentMonitor()
	monitor_size := [2]i32{rl.GetMonitorWidth(monitor), rl.GetMonitorHeight(monitor)}
	if mode == .Borderless && (monitor_size[0] <= 0 || monitor_size[1] <= 0) {return false}
	vsync := rl.IsWindowState({.VSYNC_HINT})
	if previous == .Windowed {
		engine.window.maximized = rl.IsWindowMaximized() || engine.window.pending_maximize
		if engine.window.maximized {
			// Unmaximizing is asynchronous on X11. Keep the normal geometry
			// remembered before maximization rather than capturing its old size.
			rl.RestoreWindow()
		} else {
			remember_windowed_geometry(engine)
		}
	}
	engine.window.pending_maximize = false
	// Route through windowed so raylib's shared previous-window slot cannot
	// accidentally remember a fullscreen size as the normal window size.
	if rl.IsWindowFullscreen() {rl.ToggleFullscreen()}
	if rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {rl.ToggleBorderlessWindowed()}
	rl.ClearWindowState({.WINDOW_UNDECORATED})
	if previous != .Windowed && engine.window.saved {
		resize_native_window(engine.window.size)
		rl.SetWindowPosition(i32(engine.window.position.x), i32(engine.window.position.y))
	}
	switch mode {
	case .Windowed:
		engine.window.geometry_pending_until = rl.GetTime()+1
		if engine.window.maximized {
			if !restore_maximized {
				// Hiding fullscreen must not briefly show/focus a maximized
				// surface on the way out. Apply it after an explicit reveal.
				engine.window.pending_maximize = true
			} else {
				when ODIN_OS == .Windows {rl.MaximizeWindow()} else {
					// Let the WM restore decorations and normal bounds before asking
					// it to calculate the maximized client area on a later frame.
					engine.window.pending_maximize = true
				}
			}
		}
	case .Borderless:
		// raylib 6's borderless toggle attaches a fullscreen monitor. Use a
		// normal undecorated window so desktop switching stays available, with
		// the same exported API for both static and shared raylib builds.
		rl.SetWindowState({.WINDOW_UNDECORATED})
		position := rl.GetMonitorPosition(monitor)
		rl.SetWindowPosition(i32(position.x), i32(position.y))
		resize_native_window(monitor_size)
	case .Fullscreen: rl.ToggleFullscreen()
	}
	// Monitor changes can reset the swap interval. Force the requested state.
	apply_vsync(vsync)
	succeeded := window_mode() == mode
	if succeeded && engine.window.show_pending {engine.window.startup_mode = mode}
	return succeeded
}

// Built-in loops call this after the first EndDrawing. Custom loops should do
// the same when using init(..., defer_window_show=true). Later calls are no-ops,
// preserving windows deliberately hidden by the application after startup.
// Persistent hidden mode also suppresses this automatic reveal. Use
// set_window_hidden(engine, false) for an explicit runtime reveal.
show_window :: proc(engine: ^Engine) -> bool {
	if engine == nil || !rl.IsWindowReady() {return false}
	if !engine.window.show_pending || engine.window.hidden {return true}
	return set_window_hidden(engine, false)
}

// Call during update or between frames, before BeginDrawing. Hiding retains
// the requested mode, exits exclusive fullscreen, and keeps event polling alive
// even if the window was minimized. Showing applies the latest requested mode.
// Runtime changes leave project.window.hidden unchanged.
set_window_hidden :: proc(engine: ^Engine, hidden: bool) -> bool {
	if engine == nil || !rl.IsWindowReady() {return false}
	if hidden {
		if engine.window.hidden {return rl.IsWindowHidden()}
		mode := window_mode(engine)
		if rl.IsWindowFullscreen() {
			// GLFW ignores hiding exclusive fullscreen. Hide the Win32 surface
			// before detaching the monitor, then use the normal raylib hide path.
			when ODIN_OS == .Windows {ShowWindow(rl.GetWindowHandle(), 0)}
			if !apply_window_mode(engine, .Windowed, restore_maximized = false) {return false}
		} else {
			remember_windowed_geometry(engine)
		}
		engine.window.startup_mode = mode
		engine.window.hidden_always_run = rl.IsWindowState({.WINDOW_ALWAYS_RUN})
		rl.SetWindowState({.WINDOW_ALWAYS_RUN, .WINDOW_HIDDEN})
		engine.window.hidden = true
		return rl.IsWindowHidden()
	}
	if !engine.window.hidden && !engine.window.show_pending && !rl.IsWindowHidden() && !rl.IsWindowMinimized() {return true}
	mode := window_mode(engine)
	was_hidden, was_pending := engine.window.hidden, engine.window.show_pending
	engine.window.hidden = false
	engine.window.show_pending = false
	if rl.IsWindowMinimized() {
		// raylib 6 gates RestoreWindow on GLFW_RESIZABLE, even for restoring
		// an iconified fixed-size window. Enable it only around explicit show.
		resizable := rl.IsWindowState({.WINDOW_RESIZABLE})
		if !resizable {rl.SetWindowState({.WINDOW_RESIZABLE})}
		rl.RestoreWindow()
		if !resizable {rl.ClearWindowState({.WINDOW_RESIZABLE})}
	}
	if !set_window_mode(engine, mode) {
		engine.window.hidden = was_hidden
		engine.window.show_pending = was_pending
		engine.window.startup_mode = mode
		rl.SetWindowState({.WINDOW_HIDDEN})
		return false
	}
	rl.ClearWindowState({.WINDOW_HIDDEN})
	if was_hidden {restore_hidden_event_policy(engine)}
	return !rl.IsWindowHidden()
}

@(private)
restore_hidden_event_policy :: proc(engine: ^Engine) {
	if !engine.window.hidden_always_run {rl.ClearWindowState({.WINDOW_ALWAYS_RUN})}
}

@(private)
update_window_state :: proc(engine: ^Engine) {
	if engine.window.hidden {return}
	if engine.window.pending_maximize && rl.IsWindowReady() && window_mode() == .Windowed {
		if (rl.IsWindowResized() && native_window_size() == engine.window.size) ||
		   rl.GetTime() >= engine.window.geometry_pending_until {
			engine.window.pending_maximize = false
			rl.MaximizeWindow()
		}
		return
	}
	remember_windowed_geometry(engine)
}

@(private)
remember_windowed_geometry :: proc(engine: ^Engine) {
	if !rl.IsWindowReady() || window_mode() != .Windowed || rl.IsWindowMaximized() || rl.IsWindowMinimized() {return}
	size := native_window_size()
	// Wait for the requested resize event before replacing the normal bounds
	// with framebuffer data. A WM that constrains the request can settle at
	// its own size; release the pending state after a bounded interval.
	if rl.GetTime() < engine.window.geometry_pending_until &&
	   (!rl.IsWindowResized() || size != engine.window.size) {return}
	engine.window.geometry_pending_until = 0
	engine.window.size = size
	engine.window.position = rl.GetWindowPosition()
	engine.window.saved = true
}

@(private)
resize_native_window :: proc(size: [2]i32) {
	when ODIN_OS == .Windows {
		// Avoid overwriting logical DPI dimensions when an unchanged native
		// size would not produce a resize callback to correct them.
		if native_window_size() == size {return}
	}
	// X11 framebuffer getters can still describe a previous, queued resize.
	// Always send the latest requested size so rapid mode changes restore it.
	rl.SetWindowSize(size[0], size[1])
}

@(private)
reset_window_mode :: proc() {
	// raylib retains window flags after CloseWindow. Start each Engine in a
	// decorated window before fitting it and applying the requested mode.
	if rl.IsWindowFullscreen() {rl.ToggleFullscreen()}
	if rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {rl.ToggleBorderlessWindowed()}
	rl.ClearWindowState({.WINDOW_UNDECORATED})
}

@(private)
apply_vsync :: proc(enabled: bool) {
	// SetWindowState skips already-set hints, so clear before reapplying.
	rl.ClearWindowState({.VSYNC_HINT})
	if enabled {rl.SetWindowState({.VSYNC_HINT})}
}

// Call during update or between frames. This requests display synchronization;
// the graphics driver or compositor may override the swap interval.
set_vsync :: proc(engine: ^Engine, enabled: bool) -> bool {
	if engine == nil || !rl.IsWindowReady() {return false}
	apply_vsync(enabled)
	return rl.IsWindowState({.VSYNC_HINT}) == enabled
}

// Independent of V-Sync. Zero disables the software cap; negatives are invalid.
// Runtime setters leave the loaded project settings unchanged. During fast
// stepping the new value is retained and applied when the override is released.
set_target_fps :: proc(engine: ^Engine, fps: i32) -> bool {
	if engine == nil || !rl.IsWindowReady() || fps < 0 {return false}
	rl.SetTargetFPS(0 if engine.window.step_uncapped else fps)
	engine.window.target_fps = fps
	return true
}

@(private)
set_step_uncapped :: proc(engine: ^Engine, enabled: bool) {
	if engine.window.step_uncapped == enabled {return}
	engine.window.step_uncapped = enabled
	if rl.IsWindowReady() {rl.SetTargetFPS(0 if enabled else engine.window.target_fps)}
}

toggle_borderless :: proc(engine: ^Engine) -> bool {
	return set_window_mode(engine, .Windowed if window_mode(engine) == .Borderless else .Borderless)
}

// screen matches raylib drawing/mouse coordinates. framebuffer is for GPU
// render targets. Do not multiply screen coordinates by DPI a second time.
window_metrics :: proc(engine: ^Engine = nil) -> Window_Metrics {
	if !rl.IsWindowReady() {return {}}
	return {
		mode = window_mode_name(window_mode()),
		screen = {rl.GetScreenWidth(), rl.GetScreenHeight()},
		framebuffer = {rl.GetRenderWidth(), rl.GetRenderHeight()}, dpi = rl.GetWindowScaleDPI(),
		high_dpi = rl.IsWindowState({.WINDOW_HIGHDPI}), resizable = rl.IsWindowState({.WINDOW_RESIZABLE}),
		vsync = rl.IsWindowState({.VSYNC_HINT}),
		requested_mode = window_mode_name(window_mode(engine)), hidden = rl.IsWindowHidden(),
	}
}

@(private)
window_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok {return}
	switch arguments {
	case "hidden", "show":
		if !set_window_hidden(engine, arguments == "hidden") {console.error(dev, "Window visibility change failed"); return}
	case "":
	case:
		mode, valid := parse_window_mode(arguments)
		if !valid {console.error(dev, "Usage: window [windowed|borderless|fullscreen|hidden|show]"); return}
		if !set_window_mode(engine, mode) {console.error(dev, "Window mode change failed"); return}
	}
	console.set_result(dev, window_metrics(engine))
}
