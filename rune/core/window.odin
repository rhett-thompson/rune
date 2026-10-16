package core

import "rune:console"
import rl "vendor:raylib"

Window_Mode :: enum {Windowed, Borderless, Fullscreen}

Window_State :: struct {
	// Native client size and desktop position, retained across mode changes.
	size: [2]i32,
	position: rl.Vector2,
	maximized: bool,
	saved: bool,
	geometry_pending_until: f64,
	pending_maximize: bool,
	// Runtime frame cap; project.window retains the startup settings.
	target_fps: i32,
}

Window_Metrics :: struct {
	mode: string,
	screen: [2]i32,
	framebuffer: [2]i32,
	dpi: [2]f32,
	high_dpi: bool,
	resizable: bool,
	vsync: bool,
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

window_mode :: proc() -> Window_Mode {
	if rl.IsWindowFullscreen() {return .Fullscreen}
	if rl.IsWindowState({.WINDOW_UNDECORATED}) || rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {return .Borderless}
	return .Windowed
}

// Call between frames or during update, before BeginDrawing. Idempotent.
// Changes runtime state only; project.json remains the startup configuration.
set_window_mode :: proc(engine: ^Engine, mode: Window_Mode) -> bool {
	if engine == nil || !rl.IsWindowReady() || window_mode_name(mode) == "" {return false}
	previous := window_mode()
	if previous == mode {return true}
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
			when ODIN_OS == .Windows {rl.MaximizeWindow()} else {
				// Let the WM restore decorations and normal bounds before asking
				// it to calculate the maximized client area on a later frame.
				engine.window.pending_maximize = true
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
	return window_mode() == mode
}

@(private)
update_window_state :: proc(engine: ^Engine) {
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
// Runtime setters leave the loaded project settings unchanged.
set_target_fps :: proc(engine: ^Engine, fps: i32) -> bool {
	if engine == nil || !rl.IsWindowReady() || fps < 0 {return false}
	rl.SetTargetFPS(fps)
	engine.window.target_fps = fps
	return true
}

toggle_borderless :: proc(engine: ^Engine) -> bool {
	return set_window_mode(engine, .Windowed if window_mode() == .Borderless else .Borderless)
}

// screen matches raylib drawing/mouse coordinates. framebuffer is for GPU
// render targets. Do not multiply screen coordinates by DPI a second time.
window_metrics :: proc() -> Window_Metrics {
	if !rl.IsWindowReady() {return {}}
	return {window_mode_name(window_mode()),
		{rl.GetScreenWidth(), rl.GetScreenHeight()},
		{rl.GetRenderWidth(), rl.GetRenderHeight()}, rl.GetWindowScaleDPI(),
		rl.IsWindowState({.WINDOW_HIGHDPI}), rl.IsWindowState({.WINDOW_RESIZABLE}),
		rl.IsWindowState({.VSYNC_HINT})}
}

@(private)
window_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok {return}
	if arguments != "" {
		mode, valid := parse_window_mode(arguments)
		if !valid {console.error(dev, "Usage: window [windowed|borderless|fullscreen]"); return}
		if !set_window_mode(engine, mode) {console.error(dev, "Window mode change failed"); return}
	}
	console.set_result(dev, window_metrics())
}
