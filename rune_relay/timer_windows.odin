package main

import "core:fmt"
import win32 "core:sys/windows"

// Win32 Sleep uses the process's timer resolution. Without this request the
// relay's two-millisecond poll interval can round up to roughly 16 milliseconds.
relay_timer_begin :: proc() -> bool {
	result := win32.timeBeginPeriod(1)
	if result != 0 {
		fmt.eprintf("Could not request 1 ms relay timer resolution (code %d); continuing with the system timer.\n", result)
		return false
	}
	return true
}

relay_timer_end :: proc(enabled: bool) {
	if !enabled {return}
	if result := win32.timeEndPeriod(1); result != 0 {
		fmt.eprintf("Could not release relay timer resolution (code %d).\n", result)
	}
}
