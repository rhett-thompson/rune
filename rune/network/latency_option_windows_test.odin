#+build windows
package network

import "core:net"
import win "core:sys/windows"

// Query the OS rather than assuming the requested option was applied.
latency_test_nodelay :: proc(socket: net.TCP_Socket) -> (bool, bool) {
	value: i32
	size: win.c_int = size_of(value)
	result := win.getsockopt(win.SOCKET(socket), win.IPPROTO_TCP, win.TCP_NODELAY,
		cast([^]win.c_char)&value, &size)
	return value != 0, result == 0
}
