package core

import rl "vendor:raylib"

// Declare only the monitor/geometry calls and use raylib's existing User32
// linkage. A separate User32 import can precede raylib and resolve CloseWindow
// to Win32's function before raylib's own CloseWindow definition is linked.
@(private)
Native_Rect :: struct {left, top, right, bottom: i32}
@(private)
Monitor_Info :: struct {cbSize: u32, rcMonitor, rcWork: Native_Rect, flags: u32}
@(default_calling_convention = "system")
foreign {
	GetClientRect :: proc(handle: rawptr, rect: ^Native_Rect) -> i32 ---
	GetWindowRect :: proc(handle: rawptr, rect: ^Native_Rect) -> i32 ---
	MonitorFromWindow :: proc(handle: rawptr, flags: u32) -> rawptr ---
	GetMonitorInfoW :: proc(monitor: rawptr, info: ^Monitor_Info) -> i32 ---
}

@(private)
native_window_size :: proc() -> [2]i32 {
	rect: Native_Rect
	GetClientRect(rl.GetWindowHandle(), &rect)
	return {rect.right-rect.left, rect.bottom-rect.top}
}

// Include window decorations and the taskbar when fitting the initial window.
@(private)
fit_window_to_monitor :: proc() {
	handle := rl.GetWindowHandle()
	monitor := MonitorFromWindow(handle, 2) // MONITOR_DEFAULTTONEAREST
	info := Monitor_Info{cbSize = size_of(Monitor_Info)}
	if GetMonitorInfoW(monitor, &info) == 0 {return}
	outer, client: Native_Rect
	if GetWindowRect(handle, &outer) == 0 || GetClientRect(handle, &client) == 0 {return}
	border_x := outer.right-outer.left-client.right
	border_y := outer.bottom-outer.top-client.bottom
	work := info.rcWork
	width := min(client.right, max(1, work.right-work.left-border_x-32))
	height := min(client.bottom, max(1, work.bottom-work.top-border_y-32))
	if width != client.right || height != client.bottom {rl.SetWindowSize(width, height)}
	rl.SetWindowPosition(work.left+(work.right-work.left-width-border_x)/2,
		work.top+(work.bottom-work.top-height-border_y)/2)
}
