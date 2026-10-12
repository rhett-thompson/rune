#+build linux
package network

import "core:net"
import linux "core:sys/linux"

latency_test_nodelay :: proc(socket: net.TCP_Socket) -> (bool, bool) {
	value: i32
	size := u32(size_of(value))
	result := linux.syscall(linux.SYS_getsockopt, linux.Fd(socket), int(linux.SOL_TCP),
		int(linux.Socket_TCP_Option.NODELAY), &value, &size)
	return value != 0, result == 0
}
