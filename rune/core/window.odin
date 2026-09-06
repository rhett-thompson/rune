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
}

Window_Metrics :: struct {
	mode: string,
	screen: [2]i32,
	framebuffer: [2]i32,
	dpi: [2]f32,
	high_dpi: bool,
	resizable: bool,
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
	if rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {return .Borderless}
	return .Windowed
}

// Call between frames or during update, before BeginDrawing. Idempotent.
// Changes runtime state only; project.json remains the startup configuration.
set_window_mode :: proc(engine: ^Engine, mode: Window_Mode) -> bool {
	if engine == nil || !rl.IsWindowReady() || window_mode_name(mode) == "" {return false}
	previous := window_mode()
	if previous == mode {return true}
	if previous == .Windowed {
		engine.window.maximized = rl.IsWindowMaximized()
		if engine.window.maximized {rl.RestoreWindow()}
		engine.window.size = native_window_size()
		engine.window.position = rl.GetWindowPosition()
		engine.window.saved = true
	}
	// Route through windowed so raylib's shared previous-window slot cannot
	// accidentally remember a fullscreen size as the normal window size.
	if rl.IsWindowFullscreen() {rl.ToggleFullscreen()}
	if rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {rl.ToggleBorderlessWindowed()}
	if previous != .Windowed && engine.window.saved {
		// raylib's setter writes its screen size even if the native size is
		// unchanged. In that case no resize callback runs to divide by DPI.
		if native_window_size() != engine.window.size {
			rl.SetWindowSize(engine.window.size[0], engine.window.size[1])
		}
		rl.SetWindowPosition(i32(engine.window.position.x), i32(engine.window.position.y))
	}
	switch mode {
	case .Windowed:
		if engine.window.maximized {rl.MaximizeWindow()}
	case .Borderless: rl.ToggleBorderlessWindowed()
	case .Fullscreen: rl.ToggleFullscreen()
	}
	return window_mode() == mode
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
		rl.IsWindowState({.WINDOW_HIGHDPI}), rl.IsWindowState({.WINDOW_RESIZABLE})}
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
