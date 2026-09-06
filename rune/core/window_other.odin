#+build !windows
package core

import rl "vendor:raylib"

// These symbols are provided by raylib's bundled desktop GLFW backend. Query
// native window units rather than guessing from DPI (Wayland/macOS differ).
foreign {
	glfwGetCurrentContext :: proc "c" () -> rawptr ---
	glfwGetWindowSize :: proc "c" (window: rawptr, width, height: ^i32) ---
	glfwGetMonitors :: proc "c" (count: ^i32) -> [^]rawptr ---
	glfwGetMonitorWorkarea :: proc "c" (monitor: rawptr, x,y,width,height: ^i32) ---
	glfwGetWindowFrameSize :: proc "c" (window: rawptr, left,top,right,bottom: ^i32) ---
}

@(private)
native_window_size :: proc() -> [2]i32 {
	size: [2]i32
	glfwGetWindowSize(glfwGetCurrentContext(), &size[0], &size[1])
	return size
}

// Match the work area in native desktop units; Wayland may ignore positioning.
@(private)
fit_window_to_monitor :: proc() {
	index := rl.GetCurrentMonitor()
	count: i32
	monitors := glfwGetMonitors(&count)
	if monitors == nil || index < 0 || index >= count {return}
	size := native_window_size()
	x,y,width,height,left,top,right,bottom: i32
	glfwGetMonitorWorkarea(monitors[index],&x,&y,&width,&height)
	glfwGetWindowFrameSize(glfwGetCurrentContext(),&left,&top,&right,&bottom)
	if width <= 0 || height <= 0 {return}
	previous := size
	size = {min(size[0], max(1,width-left-right-32)), min(size[1],max(1,height-top-bottom-32))}
	if size != previous {rl.SetWindowSize(size[0], size[1])}
	rl.SetWindowPosition(x+(width-size[0]-left-right)/2+left,y+(height-size[1]-top-bottom)/2+top)
}
