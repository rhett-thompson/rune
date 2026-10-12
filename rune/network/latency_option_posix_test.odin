#+build darwin, netbsd, openbsd
package network

import "core:net"
import posix "core:sys/posix"

latency_test_nodelay :: proc(socket: net.TCP_Socket) -> (bool, bool) {
	value: i32
	size := posix.socklen_t(size_of(value))
	result := posix.getsockopt(posix.FD(socket), posix.IPPROTO_TCP,
		posix.Sock_Option(posix.TCP_NODELAY), &value, &size)
	return value != 0, result == .OK
}
