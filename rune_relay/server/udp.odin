package server

import "core:net"
import "core:time"
import "rune:network"

// Limit shared-socket work independently of per-connection quotas. Unknown
// tokens use a bounded session map, so floods do not scan every room/client.
MAX_UDP_DATAGRAMS_PER_UPDATE :: 512

server_rate_accept :: proc(server: ^Server, index: int, now: time.Tick) -> bool {
	connection := &server.connections[index]
	if time.tick_diff(connection.rate_start, now) >= time.Second {
		connection.rate_start = now
		connection.packet_count = 0
	}
	connection.packet_count += 1
	if connection.packet_count > server.config.packets_per_second {
		server_error(server, index, .Invalid_Request, true)
		return false
	}
	connection.last_activity = now
	return true
}

@(private="file")
server_udp_send :: proc(server: ^Server, destination: net.Endpoint, datagram: network.UDP_Datagram) -> bool {
	buffer: [network.UDP_MAX_DATAGRAM_SIZE]u8
	size, valid := network.udp_encode(datagram, buffer[:])
	if !valid {return false}
	written, error := net.send_udp(server.udp_socket, buffer[:size], destination)
	if error != nil || written != size {
		// Preserve UDP semantics: a congested/unreachable endpoint loses the
		// datagram without blocking or moving realtime data into TCP's queue.
		server.stats.udp_dropped += 1
		return false
	}
	return true
}

server_forward_data :: proc(server: ^Server, index: int, packet: network.Packet) -> bool {
	connection := &server.connections[index]
	if connection.udp_bound && server.udp_open {
		connection.udp_send_sequence += 1
		sent := server_udp_send(server, connection.udp_endpoint, {
			kind = .Data, token = connection.udp_token,
			sequence = connection.udp_send_sequence, packet = packet,
		})
		if sent {server.stats.udp_forwarded += 1}
		return sent
	}
	return server_queue(server, index, packet)
}

server_udp_update :: proc(server: ^Server, now: time.Tick) -> bool {
	// One extra byte detects a truncated oversized datagram on platforms
	// whose recvfrom reports only the supplied buffer length.
	buffer: [network.UDP_MAX_DATAGRAM_SIZE + 1]u8
	for _ in 0..<MAX_UDP_DATAGRAMS_PER_UPDATE {
		read, source, error := net.recv_udp(server.udp_socket, buffer[:])
		if error == .Would_Block || error == .Interrupted {break}
		server.stats.udp_received += 1
		// Windows maps a truncated oversized recvfrom datagram (WSAEMSGSIZE)
		// to Invalid_Argument. Malformed traffic must never stop the relay.
		if error != nil || read <= 0 || read > network.UDP_MAX_DATAGRAM_SIZE {
			server.stats.udp_rejected += 1
			continue
		}
		datagram, valid := network.udp_decode(buffer[:read])
		if !valid {server.stats.udp_rejected += 1; continue}
		index, found := server.udp_sessions[datagram.token]
		if !found {server.stats.udp_rejected += 1; continue}
		connection := &server.connections[index]
		if !connection.transport.open || connection.failed || connection.closing || !connection.udp_issued ||
		   source.address != connection.tcp_address {
			server.stats.udp_rejected += 1
			continue
		}
		#partial switch datagram.kind {
		case .Bind:
			if !server_rate_accept(server, index, now) {server.stats.udp_rejected += 1; continue}
			newer := !connection.udp_bound || i32(datagram.sequence - connection.udp_bind_sequence) > 0
			if connection.udp_bound && source != connection.udp_endpoint && !newer {
				// A delayed bind from the old NAT port must not roll the association
				// back. Retries at the current endpoint still receive another ack.
				server.stats.udp_rejected += 1
				continue
			}
			if newer {connection.udp_bind_sequence = datagram.sequence}
			// Bind retries are idempotent and can update a NAT's source port.
			// Data never changes the association merely by claiming its token.
			connection.udp_endpoint, connection.udp_bound = source, true
			server_udp_send(server, source, {kind = .Bind_Ack, token = connection.udp_token, sequence = datagram.sequence})
		case .Data:
			if !connection.udp_bound || source != connection.udp_endpoint {
				server.stats.udp_rejected += 1
				continue
			}
			if !server_rate_accept(server, index, now) {server.stats.udp_rejected += 1; continue}
			if !network.udp_replay_accept(&connection.udp_replay, datagram.sequence) {
				server.stats.udp_rejected += 1
				continue
			}
			// The codec permits only Data frames here. Room routing then applies
			// exactly the TCP authorization checks and overwrites sender identity.
			server_handle(server, index, datagram.packet)
		case:
			server.stats.udp_rejected += 1
		}
	}
	return true
}
