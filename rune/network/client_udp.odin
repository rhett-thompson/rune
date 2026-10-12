package network

import "core:net"
import "core:time"

UDP_NEGOTIATION_TIMEOUT :: 5 * time.Second
UDP_BIND_RETRY_INTERVAL :: 100 * time.Millisecond
UDP_HEARTBEAT_INTERVAL :: time.Second

@(private="package")
client_udp_fail :: proc(client: ^Client) {
	client.udp_failed = true
	disconnect(client)
}

@(private="package")
client_udp_start :: proc(client: ^Client, remote: net.Endpoint) -> net.Network_Error {
	if remote.address == nil || remote.port < 1 || remote.port > 65535 {return net.Dial_Error.Invalid_Argument}
	socket, create_error := net.make_unbound_udp_socket(net.family_from_address(remote.address))
	if create_error != nil {return create_error}
	client.udp_socket, client.udp_open, client.udp_remote = socket, true, remote
	local: net.Address = net.IP4_Any
	if _, ipv6 := remote.address.(net.IP6_Address); ipv6 {local = net.IP6_Any}
	if error := net.bind(socket, {local, 0}); error != nil {return error}
	if error := net.set_blocking(socket, false); error != nil {return error}
	client.udp_started, client.udp_last_received = time.tick_now(), time.tick_now()
	return nil
}

@(private="package")
client_udp_maintenance :: proc(client: ^Client, now: time.Tick) -> bool {
	if !client.udp_requested {return true}
	if !client.udp_ready && time.tick_diff(client.udp_started, now) >= UDP_NEGOTIATION_TIMEOUT {
		client_udp_fail(client); return false
	}
	if client.udp_ready && time.tick_diff(client.udp_last_received, now) >= CLIENT_TIMEOUT {
		client_udp_fail(client); return false
	}
	if !client.udp_session {return true}
	interval := UDP_HEARTBEAT_INTERVAL if client.udp_ready else UDP_BIND_RETRY_INTERVAL
	if client.udp_last_bind != (time.Tick{}) && time.tick_diff(client.udp_last_bind, now) < interval {return true}
	client.udp_bind_sequence += 1
	client.udp_last_bind = now
	bytes: [UDP_HEADER_SIZE]u8
	size, encoded := udp_encode({kind = .Bind, token = client.udp_token, sequence = client.udp_bind_sequence}, bytes[:])
	if !encoded {client_udp_fail(client); return false}
	sent := time.tick_now()
	written, error := net.send_udp(client.udp_socket, bytes[:size], client.udp_remote)
	if error != nil || written != size {client.udp_dropped += 1}
	if error == .Would_Block || error == .Interrupted || error == .Insufficient_Resources {return true}
	if error != nil || written != size {client_udp_fail(client); return false}
	traffic_record(&client.measurements.udp_traffic, {tx_bytes = u64(written), tx_packets = 1}, time.tick_now())
	client_bind_sent(client, client.udp_bind_sequence, sent)
	return true
}

@(private="package")
client_udp_send :: proc(client: ^Client, packet: Packet) -> bool {
	if !client.udp_open {client_udp_fail(client); return false}
	client.udp_send_sequence += 1
	bytes: [UDP_MAX_DATAGRAM_SIZE]u8
	size, encoded := udp_encode({kind = .Data, token = client.udp_token, sequence = client.udp_send_sequence, packet = packet}, bytes[:])
	if !encoded {return false}
	client.udp_datagrams_sent += 1
	written, error := net.send_udp(client.udp_socket, bytes[:size], client.udp_remote)
	if error != nil || written != size {client.udp_dropped += 1}
	if error == .Would_Block || error == .Interrupted || error == .Insufficient_Resources {
		return true
	}
	if error != nil || written != size {client_udp_fail(client); return false}
	traffic_record(&client.measurements.udp_traffic, {tx_bytes = u64(written), tx_packets = 1}, time.tick_now())
	return true
}

@(private="package")
client_udp_poll :: proc(client: ^Client, now: time.Tick) -> (Packet, bool, bool) {
	// One extra byte distinguishes an oversized datagram from a maximum frame.
	bytes: [UDP_MAX_DATAGRAM_SIZE+1]u8
	for _ in 0..<32 {
		read, source, error := net.recv_udp(client.udp_socket, bytes[:])
		if error == .Would_Block || error == .Interrupted {break}
		// ICMP refusal and malformed oversized datagrams are not authenticated
		// session events. Let retry/deadline logic handle a blocked UDP route.
		if error == .Connection_Refused || error == .Excess_Truncated || error == .Invalid_Argument {
			client.udp_datagrams_rejected += 1
			client.measurements.udp_invalid += 1
			if error == .Excess_Truncated {traffic_record(&client.measurements.udp_traffic, {rx_bytes = u64(max(read, 0)), rx_packets = 1}, time.tick_now())}
			continue
		}
		if error != nil {client_udp_fail(client); return {}, false, false}
		if read < 0 || read > len(bytes) {client_udp_fail(client); return {}, false, false}
		traffic_record(&client.measurements.udp_traffic, {rx_bytes = u64(read), rx_packets = 1}, time.tick_now())
		value, valid := udp_decode(bytes[:read])
		if !valid || !client.udp_session || value.token != client.udp_token || !udp_endpoint_equal(source, client.udp_remote) {
			client.measurements.udp_invalid += 1
			client.udp_datagrams_rejected += 1; continue
		}
		switch value.kind {
		case .Bind_Ack:
			if client.udp_last_bind == (time.Tick{}) ||
			   (value.sequence != client.udp_bind_sequence && i32(client.udp_bind_sequence-value.sequence) <= 0) {
				client.measurements.udp_invalid += 1
				client.udp_datagrams_rejected += 1; continue
			}
			client_bind_acknowledged(client, value.sequence, time.tick_now())
			client.udp_ready = true
			client.udp_last_received = now
		case .Data:
			packet := value.packet
			if !client.udp_ready || client.status != .In_Room || packet.peer == 0 || packet.peer == client.peer_id ||
			   (!client.is_host && packet.peer != 1) {
				client.measurements.udp_invalid += 1
				client.udp_datagrams_rejected += 1; continue
			}
			client_observe_udp(client, value.sequence)
			if !udp_replay_accept(&client.udp_replay, value.sequence) {
				client.udp_datagrams_rejected += 1; continue
			}
			client.udp_last_received, client.last_received = now, now
			client.udp_datagrams_received += 1
			return packet, true, true
		case .Bind:
			client.udp_datagrams_rejected += 1
			client.measurements.udp_invalid += 1
		}
	}
	return {}, false, true
}
