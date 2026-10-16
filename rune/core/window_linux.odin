package core

import "core:c"
import rl "vendor:raylib"

// Reuse raylib's existing X11 linkage. This separate connection reads only
// root-window properties; it does not access raylib's private GLFW state or
// interpret GetWindowHandle(), whose representation depends on the backend.
@(default_calling_convention = "c")
foreign {
	XOpenDisplay :: proc(name: cstring) -> rawptr ---
	XCloseDisplay :: proc(display: rawptr) -> c.int ---
	XDefaultRootWindow :: proc(display: rawptr) -> c.ulong ---
	XInternAtom :: proc(display: rawptr, name: cstring, only_if_exists: c.int) -> c.ulong ---
	XGetWindowProperty :: proc(display: rawptr, window, property: c.ulong, offset, length: c.long,
		delete_property: c.int, requested_type: c.ulong, actual_type: ^c.ulong, actual_format: ^c.int,
		item_count, bytes_after: ^c.ulong, data: ^rawptr) -> c.int ---
	XFree :: proc(data: rawptr) -> c.int ---
}

@(private)
x11_read_cardinals :: proc(display: rawptr, window: c.ulong, property: cstring, offset: c.long, values: []u32) -> bool {
	max_cardinals :: 4096
	if offset < 0 || offset > max_cardinals || len(values) > max_cardinals-int(offset) {return false}
	requested_count := offset+c.long(len(values))
	atom := XInternAtom(display, property, 1)
	if atom == 0 {return false}
	cardinal :: c.ulong(6) // XA_CARDINAL
	actual_type, item_count, bytes_after: c.ulong
	actual_format: c.int
	data: rawptr
	// Starting beyond a truncated property raises BadValue. Read from zero
	// and check the item count before selecting the requested desktop.
	status := XGetWindowProperty(display, window, atom, 0, requested_count, 0, cardinal,
		&actual_type, &actual_format, &item_count, &bytes_after, &data)
	defer {if data != nil {XFree(data)}}
	if status != 0 || actual_type != cardinal || actual_format != 32 || data == nil || item_count < c.ulong(requested_count) {
		return false
	}
	// Xlib returns format-32 properties in native C longs, including on LP64.
	items := ([^]c.ulong)(data)
	for &value, index in values {value = u32(items[int(offset)+index])}
	return true
}

@(private)
linux_monitor_workarea :: proc(position: rl.Vector2, size: [2]i32) -> (rl.Vector2, [2]i32) {
	if size[0] <= 0 || size[1] <= 0 {return position, size}
	display := XOpenDisplay(nil)
	if display == nil {return position, size}
	defer XCloseDisplay(display)
	root := XDefaultRootWindow(display)
	desktop: [1]u32
	if !x11_read_cardinals(display, root, "_NET_CURRENT_DESKTOP", 0, desktop[:]) {return position, size}
	// Bound the property read to 1024 desktops (4096 CARDINALs).
	if desktop[0] >= 1024 {return position, size}
	work: [4]u32
	if !x11_read_cardinals(display, root, "_NET_WORKAREA", c.long(desktop[0])*4, work[:]) {return position, size}
	if work[2] == 0 || work[3] == 0 {return position, size}

	// EWMH describes a desktop-wide rectangle. Restrict it to this monitor,
	// and retain monitor bounds when the WM has no usable intersection.
	left := max(i64(position.x), i64(i32(work[0])))
	top := max(i64(position.y), i64(i32(work[1])))
	right := min(i64(position.x)+i64(size[0]), i64(i32(work[0]))+i64(work[2]))
	bottom := min(i64(position.y)+i64(size[1]), i64(i32(work[1]))+i64(work[3]))
	if right <= left || bottom <= top {return position, size}
	return {f32(left), f32(top)}, {i32(right-left), i32(bottom-top)}
}
