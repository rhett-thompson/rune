#+build !windows
package core

import rl "vendor:raylib"

@(private)
native_window_size :: proc() -> [2]i32 {
	when ODIN_OS == .Darwin {
		// Cocoa window sizes use points, while the framebuffer uses pixels.
		return {rl.GetScreenWidth(), rl.GetScreenHeight()}
	} else {
		// The supported Linux toolchain uses X11, whose native client size is
		// the framebuffer size. Query outside render-texture drawing, as the
		// public render getters otherwise describe the bound render texture.
		return {rl.GetRenderWidth(), rl.GetRenderHeight()}
	}
}

@(private)
native_monitor_workarea :: proc(monitor: i32) -> (position: rl.Vector2, size: [2]i32) {
	position = rl.GetMonitorPosition(monitor)
	size = {rl.GetMonitorWidth(monitor), rl.GetMonitorHeight(monitor)}
	when ODIN_OS == .Linux {
		return linux_monitor_workarea(position, size)
	} else {
		// raylib has no public work-area getter. Other desktop platforms use
		// monitor bounds and leave a margin for window decorations.
		return
	}
}

// Use exported raylib APIs and the desktop work area where it is available.
@(private)
fit_window_to_monitor :: proc() -> (size: [2]i32, position: rl.Vector2) {
	if !rl.IsWindowReady() {return}
	size = native_window_size()
	position = rl.GetWindowPosition()
	index := rl.GetCurrentMonitor()
	if index < 0 || index >= rl.GetMonitorCount() {return}
	work_position, work_size := native_monitor_workarea(index)
	if work_size[0] <= 0 || work_size[1] <= 0 {return}

	previous := size
	// Reserve space on each edge; public raylib does not expose frame extents.
	margin :: 32
	size = {min(size[0], max(1, work_size[0]-2*margin)), min(size[1], max(1, work_size[1]-2*margin))}
	if size != previous {rl.SetWindowSize(size[0], size[1])}
	position = {work_position.x+f32((work_size[0]-size[0])/2), work_position.y+f32((work_size[1]-size[1])/2)}
	rl.SetWindowPosition(i32(position.x), i32(position.y))
	return
}
