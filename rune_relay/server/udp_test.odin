package server

import "core:mem"
import "core:net"
import "core:testing"
import "core:time"
import "rune:network"

udp_test_connect :: proc(server: ^Server) -> network.Transport {
	socket, error := net.dial_tcp(net.endpoint_to_string(server.endpoint))
	assert(error == nil)
	transport: network.Transport
	assert(network.transport_init(&transport, socket))
	assert(server_update(server))
	return transport
}

udp_test_tcp_read :: proc(server: ^Server, transport: ^network.Transport) -> network.Packet {
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		assert(network.transport_flush(transport) && server_update(server))
		assert(network.transport_receive(transport))
		packet, available, valid := network.transport_next(transport)
		assert(valid)
		if available {return packet}
		time.sleep(time.Millisecond)
	}
	panic("timed out waiting for relay TCP event")
}

udp_test_enable :: proc(server: ^Server, transport: ^network.Transport) -> [network.UDP_TOKEN_SIZE]u8 {
	assert(network.transport_queue(transport, {kind = .UDP_Enable}))
	packet := udp_test_tcp_read(server, transport)
	assert(packet.kind == .UDP_Session && packet.peer == 0 && packet.payload_size == network.UDP_TOKEN_SIZE)
	token: [network.UDP_TOKEN_SIZE]u8
	copy(token[:], packet.payload[:network.UDP_TOKEN_SIZE])
	assert(network.udp_token_valid(token))
	return token
}

udp_test_socket :: proc(address := net.IP4_Loopback) -> net.UDP_Socket {
	socket, error := net.make_bound_udp_socket(address, 0)
	assert(error == nil && net.set_blocking(socket, false) == nil)
	return socket
}

udp_test_send :: proc(socket: net.UDP_Socket, endpoint: net.Endpoint, datagram: network.UDP_Datagram) {
	buffer: [network.UDP_MAX_DATAGRAM_SIZE]u8
	size, valid := network.udp_encode(datagram, buffer[:])
	assert(valid)
	written, error := net.send_udp(socket, buffer[:size], endpoint)
	assert(error == nil && written == size)
}

udp_test_read :: proc(server: ^Server, socket: net.UDP_Socket) -> network.UDP_Datagram {
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		assert(server_update(server))
		buffer: [network.UDP_MAX_DATAGRAM_SIZE]u8
		read, source, error := net.recv_udp(socket, buffer[:])
		if error == .Would_Block || error == .Interrupted {time.sleep(time.Millisecond); continue}
		assert(error == nil && source == server.endpoint)
		datagram, valid := network.udp_decode(buffer[:read])
		assert(valid)
		return datagram
	}
	panic("timed out waiting for relay UDP event")
}

udp_test_bind :: proc(server: ^Server, socket: net.UDP_Socket, token: [network.UDP_TOKEN_SIZE]u8, sequence := u32(1)) {
	udp_test_send(socket, server.endpoint, {kind = .Bind, token = token, sequence = sequence})
	response := udp_test_read(server, socket)
	assert(response.kind == .Bind_Ack && response.token == token && response.sequence == sequence)
}

udp_test_data :: proc(peer: u32, value: u8) -> network.Packet {
	packet := network.Packet{kind = .Data, peer = peer, payload_size = 1}
	packet.payload[0] = value
	return packet
}

// Socket authentication/routing tests provide membership directly. A separate
// end-to-end test exercises Create/Join/Leave with the public client API.
udp_test_pair_room :: proc(server: ^Server) {
	assert(server.stats.connections == 2)
	server.rooms[0] = {active = true, capacity = 2, members = 2, next_peer = 3}
	server.stats.rooms = 1
	for &connection, index in server.connections[:2] {connection.room, connection.peer = 0, u32(index + 1)}
}

udp_test_client_event :: proc(server: ^Server, client: ^network.Client, kind: network.Kind) -> network.Packet {
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		assert(server_update(server))
		packet, available, ok := network.poll(client)
		assert(ok)
		if available && packet.kind == kind {return packet}
		if !available {time.sleep(time.Millisecond)}
	}
	panic("timed out waiting for public client event")
}

udp_test_client_ready :: proc(server: ^Server, client: ^network.Client) {
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		assert(server_update(server))
		_, _, ok := network.poll(client)
		assert(ok)
		if client.udp_ready {return}
		time.sleep(time.Millisecond)
	}
	panic("timed out waiting for public client UDP binding")
}

@(test)
relay_udp_same_port_start_stop_and_bind_failure_cleanup :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2}) == "")
	testing.expect(t, server.udp_open && server.config.udp_enabled)
	endpoint, error := net.bound_endpoint(server.udp_socket)
	testing.expect(t, error == nil && endpoint == server.endpoint && endpoint.port > 0)
	server_stop(&server)
	testing.expect(t, !server.udp_open && len(server.udp_sessions) == 0)
	blocker := udp_test_socket()
	defer net.close(blocker)
	endpoint, error = net.bound_endpoint(blocker)
	assert(error == nil)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	previous := context.allocator
	context.allocator = mem.tracking_allocator(&tracker)
	start_error := server_start(&server, {listen = endpoint, max_connections = 2})
	context.allocator = previous
	testing.expect(t, start_error != "" && !server.running)
	testing.expect_value(t, tracker.current_memory_allocated, i64(0))
	testing.expect_value(t, len(tracker.bad_free_array), 0)
	// Failed UDP startup must also close the already-created TCP listener.
	testing.expect_value(t, server_start(&server, {listen = endpoint, max_connections = 2, udp_configured = true}), "")
	testing.expect(t, server.running && !server.udp_open)
	server_stop(&server)
}

@(test)
relay_udp_negotiation_is_idempotent_unique_and_disabled_is_explicit :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2}) == "")
	defer server_stop(&server)
	first, second := udp_test_connect(&server), udp_test_connect(&server)
	defer network.transport_close(&first)
	defer network.transport_close(&second)
	first_token := udp_test_enable(&server, &first)
	second_token := udp_test_enable(&server, &second)
	testing.expect(t, first_token != second_token)
	testing.expect_value(t, udp_test_enable(&server, &first), first_token)
	testing.expect_value(t, len(server.udp_sessions), 2)
	for invalid in ([2]network.Packet{{kind = .UDP_Enable, peer = 1}, {kind = .UDP_Enable, payload_size = 1}}) {
		assert(network.transport_queue(&first, invalid))
		response := udp_test_tcp_read(&server, &first)
		testing.expect(t, response.kind == .Error && response.payload[0] == u8(network.Error_Code.Invalid_Request))
	}
	server_stop(&server)
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, udp_configured = true}) == "")
	disabled := udp_test_connect(&server)
	defer network.transport_close(&disabled)
	assert(network.transport_queue(&disabled, {kind = .UDP_Enable}))
	response := udp_test_tcp_read(&server, &disabled)
	testing.expect(t, response.kind == .Error && response.payload[0] == u8(network.Error_Code.UDP_Unavailable))
	assert(network.transport_queue(&disabled, {kind = .Ping}))
	testing.expect_value(t, udp_test_tcp_read(&server, &disabled).kind, network.Kind.Pong)
}

@(test)
relay_udp_bind_retry_nat_rebinding_and_wrong_ip_authentication :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2}) == "")
	defer server_stop(&server)
	transport := udp_test_connect(&server)
	defer network.transport_close(&transport)
	token := udp_test_enable(&server, &transport)
	first, rebound, other_ip := udp_test_socket(), udp_test_socket(), udp_test_socket(net.IP4_Address{127, 0, 0, 2})
	defer net.close(first)
	defer net.close(rebound)
	defer net.close(other_ip)
	udp_test_bind(&server, first, token, 40)
	// Ignore a received ack as if the network dropped it; the exact retry must
	// still receive another ack and must not consume a data replay sequence.
	udp_test_bind(&server, first, token, 40)
	first_endpoint := server.connections[0].udp_endpoint
	udp_test_send(other_ip, server.endpoint, {kind = .Bind, token = token, sequence = 41})
	assert(server_update(&server))
	testing.expect_value(t, server.connections[0].udp_endpoint, first_endpoint)
	testing.expect_value(t, server.stats.udp_rejected, u64(1))
	udp_test_bind(&server, rebound, token, 42)
	rebound_endpoint, error := net.bound_endpoint(rebound)
	testing.expect(t, error == nil && server.connections[0].udp_endpoint == rebound_endpoint)
	udp_test_send(first, server.endpoint, {kind = .Bind, token = token, sequence = 40})
	assert(server_update(&server))
	testing.expect(t, server.connections[0].udp_endpoint == rebound_endpoint, "delayed old-port binding cannot undo a newer NAT association")
	testing.expect_value(t, server.stats.udp_rejected, u64(2))
	udp_test_bind(&server, rebound, token, 42)
	testing.expect(t, server.connections[0].udp_bound && !server.connections[0].udp_replay.has_latest)
}

@(test)
relay_udp_mixed_transport_routing_authenticates_sender_and_room_target :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
	defer server_stop(&server)
	host, guest := udp_test_connect(&server), udp_test_connect(&server)
	defer network.transport_close(&host)
	defer network.transport_close(&guest)
	udp_test_pair_room(&server)
	guest_token := udp_test_enable(&server, &guest)
	guest_udp := udp_test_socket()
	defer net.close(guest_udp)
	udp_test_bind(&server, guest_udp, guest_token)
	// UDP guest -> TCP-only host uses the TCP bootstrap/compatibility path.
	udp_test_send(guest_udp, server.endpoint, {kind = .Data, token = guest_token, sequence = 10, packet = udp_test_data(1, 7)})
	packet := udp_test_tcp_read(&server, &host)
	testing.expect(t, packet.kind == .Data && packet.peer == 2 && packet.payload[0] == 7)
	// TCP host -> UDP guest chooses the recipient's bound transport.
	assert(network.transport_queue(&host, udp_test_data(2, 9)) && network.transport_flush(&host))
	datagram := udp_test_read(&server, guest_udp)
	testing.expect(t, datagram.kind == .Data && datagram.token == guest_token && datagram.packet.peer == 1 && datagram.packet.payload[0] == 9)
	testing.expect_value(t, server.stats.forwarded, u64(2))
	testing.expect_value(t, server.stats.udp_forwarded, u64(1))
	udp_test_send(guest_udp, server.endpoint, {kind = .Data, token = guest_token, sequence = 11, packet = udp_test_data(0, 20)})
	packet = udp_test_tcp_read(&server, &guest)
	testing.expect(t, packet.kind == .Error && packet.payload[0] == u8(network.Error_Code.Forbidden))
	testing.expect_value(t, server.stats.forwarded, u64(2))
}

@(test)
relay_udp_data_rejects_unbound_wrong_token_and_unbound_source_without_poisoning_replay :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
	defer server_stop(&server)
	host, guest := udp_test_connect(&server), udp_test_connect(&server)
	defer network.transport_close(&host)
	defer network.transport_close(&guest)
	udp_test_pair_room(&server)
	token := udp_test_enable(&server, &guest)
	legitimate, impostor := udp_test_socket(), udp_test_socket()
	defer net.close(legitimate)
	defer net.close(impostor)
	data := network.UDP_Datagram{kind = .Data, token = token, sequence = 100, packet = udp_test_data(1, 23)}
	udp_test_send(legitimate, server.endpoint, data)
	assert(server_update(&server))
	testing.expect(t, !server.connections[1].udp_replay.has_latest && server.stats.forwarded == 0)
	udp_test_bind(&server, legitimate, token)
	udp_test_send(impostor, server.endpoint, data)
	wrong_token := data
	wrong_token.token[0] ~= 1
	udp_test_send(legitimate, server.endpoint, wrong_token)
	assert(server_update(&server))
	testing.expect_value(t, server.stats.udp_rejected, u64(3))
	testing.expect(t, !server.connections[1].udp_replay.has_latest && server.stats.forwarded == 0)
	udp_test_send(legitimate, server.endpoint, data)
	packet := udp_test_tcp_read(&server, &host)
	testing.expect(t, packet.peer == 2 && packet.payload[0] == 23)
	testing.expect_value(t, server.stats.forwarded, u64(1))
}

@(test)
relay_udp_loss_reorder_duplicates_and_replay_window_preserve_unreliable_delivery :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
	defer server_stop(&server)
	host, guest := udp_test_connect(&server), udp_test_connect(&server)
	defer network.transport_close(&host)
	defer network.transport_close(&guest)
	udp_test_pair_room(&server)
	host_token, guest_token := udp_test_enable(&server, &host), udp_test_enable(&server, &guest)
	host_udp, guest_udp := udp_test_socket(), udp_test_socket()
	defer net.close(host_udp)
	defer net.close(guest_udp)
	udp_test_bind(&server, host_udp, host_token)
	udp_test_bind(&server, guest_udp, guest_token)
	// Sequence 9 never arrives. Later messages and late messages within the
	// replay window are immediately forwarded; no missing-packet wait occurs.
	for sequence in ([]u32{12, 10, 11, 12, 100, 20}) {
		udp_test_send(guest_udp, server.endpoint, {kind = .Data, token = guest_token, sequence = sequence, packet = udp_test_data(1, u8(sequence))})
		assert(server_update(&server))
	}
	for value, index in ([]u8{12, 10, 11, 100}) {
		datagram := udp_test_read(&server, host_udp)
		testing.expect(t, datagram.kind == .Data && datagram.packet.peer == 2 && datagram.packet.payload[0] == value)
		testing.expect_value(t, datagram.sequence, u32(index + 1))
	}
	testing.expect_value(t, server.stats.forwarded, u64(4))
	testing.expect_value(t, server.stats.udp_rejected, u64(2))
	testing.expect_value(t, server.connections[0].transport.send_count, 0)
	assert(network.transport_receive(&host))
	_, available, valid := network.transport_next(&host)
	testing.expect(t, valid && !available, "bound realtime data must not be duplicated into TCP")
}

@(test)
relay_udp_tcp_lifetime_revokes_token_across_connection_slot_reuse :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
	defer server_stop(&server)
	host, guest := udp_test_connect(&server), udp_test_connect(&server)
	defer network.transport_close(&host)
	defer network.transport_close(&guest)
	udp_test_pair_room(&server)
	token := udp_test_enable(&server, &guest)
	guest_udp := udp_test_socket()
	defer net.close(guest_udp)
	udp_test_bind(&server, guest_udp, token)
	assert(network.transport_queue(&guest, {kind = .Leave}) && network.transport_flush(&guest))
	packet := udp_test_tcp_read(&server, &host)
	testing.expect(t, packet.kind == .Peer_Left && packet.peer == 2)
	testing.expect(t, !server.connections[1].transport.open && len(server.udp_sessions) == 0)
	replacement := udp_test_connect(&server)
	defer network.transport_close(&replacement)
	new_token := udp_test_enable(&server, &replacement)
	testing.expect(t, new_token != token && server.connections[1].udp_issued && !server.connections[1].udp_bound)
	udp_test_send(guest_udp, server.endpoint, {kind = .Bind, token = token, sequence = 2})
	udp_test_send(guest_udp, server.endpoint, {kind = .Data, token = token, sequence = 3, packet = udp_test_data(1, 33)})
	assert(server_update(&server))
	testing.expect(t, !server.connections[1].udp_bound && server.stats.forwarded == 0)
	testing.expect_value(t, server.stats.udp_rejected, u64(2))
	server.connections[1].last_activity = time.tick_add(server.connections[1].last_activity, -server.config.idle_timeout)
	assert(server_update(&server))
	testing.expect(t, !server.connections[1].transport.open && len(server.udp_sessions) == 0)
}

@(test)
relay_udp_rate_limit_is_shared_with_tcp_and_closes_over_budget_sender :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 1, packets_per_second = 3}) == "")
	defer server_stop(&server)
	transport := udp_test_connect(&server)
	defer network.transport_close(&transport)
	token := udp_test_enable(&server, &transport) // packet 1, TCP
	socket := udp_test_socket()
	defer net.close(socket)
	udp_test_bind(&server, socket, token) // packet 2, UDP
	assert(network.transport_queue(&transport, {kind = .Ping}))
	testing.expect_value(t, udp_test_tcp_read(&server, &transport).kind, network.Kind.Pong) // packet 3, TCP
	udp_test_send(socket, server.endpoint, {kind = .Bind, token = token, sequence = 2}) // packet 4, UDP
	packet := udp_test_tcp_read(&server, &transport)
	testing.expect(t, packet.kind == .Error && packet.payload[0] == u8(network.Error_Code.Invalid_Request))
	testing.expect(t, server.connections[0].closing && server.connections[0].packet_count == 4)
	testing.expect_value(t, server.stats.udp_rejected, u64(1))
}

@(test)
relay_udp_oversized_malformed_and_control_datagrams_cannot_stop_relay :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
	defer server_stop(&server)
	host, guest := udp_test_connect(&server), udp_test_connect(&server)
	defer network.transport_close(&host)
	defer network.transport_close(&guest)
	udp_test_pair_room(&server)
	token := udp_test_enable(&server, &guest)
	socket := udp_test_socket()
	defer net.close(socket)
	udp_test_bind(&server, socket, token)
	oversized: [network.UDP_MAX_DATAGRAM_SIZE + 200]u8
	written, error := net.send_udp(socket, oversized[:], server.endpoint)
	assert(error == nil && written == len(oversized))
	malformed := [3]u8{'R', 'U', 'N'}
	written, error = net.send_udp(socket, malformed[:], server.endpoint)
	assert(error == nil && written == len(malformed))
	// A syntactically complete TCP Ping framed inside UDP Data must not be
	// admitted through the realtime transport or change TCP room state.
	buffer: [network.UDP_MAX_DATAGRAM_SIZE]u8
	header_size, encoded := network.udp_encode({kind = .Bind, token = token, sequence = 10}, buffer[:])
	assert(encoded)
	buffer[5] = u8(network.UDP_Datagram_Kind.Data)
	frame_size, frame_ok := network.frame_encode({kind = .Leave}, buffer[header_size:])
	assert(frame_ok)
	written, error = net.send_udp(socket, buffer[:header_size + frame_size], server.endpoint)
	assert(error == nil && written == header_size + frame_size)
	assert(server_update(&server))
	testing.expect(t, server.running && server.connections[1].transport.open && server.connections[1].room == 0)
	testing.expect_value(t, server.stats.udp_rejected, u64(3))
	udp_test_send(socket, server.endpoint, {kind = .Data, token = token, sequence = 10, packet = udp_test_data(1, 91)})
	packet := udp_test_tcp_read(&server, &host)
	testing.expect(t, packet.kind == .Data && packet.payload[0] == 91)
	testing.expect_value(t, server.stats.forwarded, u64(1))
}

@(test)
relay_udp_unknown_token_flood_has_bounded_work_and_preserves_tcp_control :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 1}) == "")
	defer server_stop(&server)
	transport := udp_test_connect(&server)
	defer network.transport_close(&transport)
	socket := udp_test_socket()
	defer net.close(socket)
	assert(net.set_option(server.udp_socket, .Receive_Buffer_Size, 1024 * 1024) == nil)
	token: [network.UDP_TOKEN_SIZE]u8
	token[0] = 1 // Valid wire token, absent from the bounded session map.
	for sequence in 0..<MAX_UDP_DATAGRAMS_PER_UPDATE + 1 {
		udp_test_send(socket, server.endpoint, {kind = .Bind, token = token, sequence = u32(sequence)})
	}
	assert(network.transport_queue(&transport, {kind = .Ping}) && network.transport_flush(&transport))
	assert(server_update(&server))
	testing.expect_value(t, server.stats.udp_received, u64(MAX_UDP_DATAGRAMS_PER_UPDATE))
	testing.expect_value(t, server.stats.udp_rejected, u64(MAX_UDP_DATAGRAMS_PER_UPDATE))
	testing.expect(t, server.connections[0].packet_count == 1, "unknown UDP traffic must not spend a TCP client's authenticated quota")
	testing.expect(t, server.connections[0].transport.send_count == 0, "TCP Pong must be flushed despite a UDP flood")
	testing.expect_value(t, udp_test_tcp_read(&server, &transport).kind, network.Kind.Pong)
	testing.expect_value(t, server.stats.udp_received, u64(MAX_UDP_DATAGRAMS_PER_UPDATE + 1))
}

@(test)
relay_udp_public_clients_negotiate_join_exchange_data_and_close_room_over_tcp :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
	defer server_stop(&server)
	host, guest: network.Client
	defer network.disconnect(&host)
	defer network.disconnect(&guest)
	assert(network.connect(&host, net.endpoint_to_string(server.endpoint), true) == nil)
	assert(network.create_room(&host, 2))
	welcome := udp_test_client_event(&server, &host, .Welcome)
	udp_test_client_ready(&server, &host)
	testing.expect(t, host.status == .In_Room && host.udp_requested && host.udp_ready && welcome.peer == 1)
	assert(network.connect(&guest, net.endpoint_to_string(server.endpoint), true) == nil)
	assert(network.join_room(&guest, string(host.room_code[:])))
	joined := udp_test_client_event(&server, &guest, .Joined)
	udp_test_client_ready(&server, &guest)
	testing.expect(t, guest.status == .In_Room && guest.udp_ready && joined.peer == 2)
	testing.expect_value(t, udp_test_client_event(&server, &host, .Peer_Joined).peer, u32(2))
	assert(network.send(&guest, []u8{47}, 1))
	packet := udp_test_client_event(&server, &host, .Data)
	testing.expect(t, packet.peer == 2 && packet.payload_size == 1 && packet.payload[0] == 47)
	assert(network.send(&host, []u8{42}, 0))
	packet = udp_test_client_event(&server, &guest, .Data)
	testing.expect(t, packet.peer == 1 && packet.payload[0] == 42)
	testing.expect_value(t, server.stats.udp_forwarded, u64(2))
	token := guest.udp_token
	network.disconnect(&host)
	testing.expect_value(t, udp_test_client_event(&server, &guest, .Room_Closed).kind, network.Kind.Room_Closed)
	testing.expect(t, guest.status == .Disconnected && !guest.udp_open && len(server.udp_sessions) == 0)
	testing.expect(t, server.stats.rooms == 0 && !server.connections[1].udp_issued)
	attacker := udp_test_socket()
	defer net.close(attacker)
	udp_test_send(attacker, server.endpoint, {kind = .Bind, token = token, sequence = 100})
	assert(server_update(&server))
	testing.expect_value(t, server.stats.udp_rejected, u64(1))
}

@(test)
relay_host_departed_peer_data_drops_without_error_and_replacement_can_join :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
	defer server_stop(&server)
	host, guest, replacement: network.Client
	defer network.disconnect(&host)
	defer network.disconnect(&guest)
	defer network.disconnect(&replacement)
	assert(network.connect(&host, net.endpoint_to_string(server.endpoint)) == nil && network.create_room(&host, 2))
	udp_test_client_event(&server, &host, .Welcome)
	assert(network.connect(&guest, net.endpoint_to_string(server.endpoint)) == nil)
	assert(network.join_room(&guest, string(host.room_code[:])))
	departed_peer := udp_test_client_event(&server, &guest, .Joined).peer
	udp_test_client_event(&server, &host, .Peer_Joined)
	network.disconnect(&guest)
	started := time.tick_now()
	for server.stats.connections != 1 && time.tick_since(started) < time.Second {assert(server_update(&server)); time.sleep(time.Millisecond)}
	assert(server.stats.connections == 1 && server.rooms[0].members == 1)
	// The departure is already known to the relay, but its reliable control
	// event has not yet been consumed by the host's application.
	probe := []u8{1, 5, 0, 0, 0, 1}
	assert(network.send(&host, probe, departed_peer))
	testing.expect_value(t, udp_test_client_event(&server, &host, .Peer_Left).peer, departed_peer)
	testing.expect(t, host.status == .In_Room && host.transport.open && server.stats.rejected == 0 && server.stats.forwarded == 0)
	assert(network.connect(&replacement, net.endpoint_to_string(server.endpoint)) == nil)
	assert(network.join_room(&replacement, string(host.room_code[:])))
	new_peer := udp_test_client_event(&server, &replacement, .Joined).peer
	testing.expect(t, new_peer > departed_peer)
	testing.expect_value(t, udp_test_client_event(&server, &host, .Peer_Joined).peer, new_peer)
	assert(network.send(&replacement, []u8{77}, 1))
	packet := udp_test_client_event(&server, &host, .Data)
	testing.expect(t, packet.peer == new_peer && packet.payload[0] == 77)
	// An old target must not accidentally route to the reused connection slot.
	assert(network.send(&host, probe, departed_peer))
	assert(server_update(&server))
	testing.expect(t, server.stats.rejected == 0 && server.stats.forwarded == 1 && server.stats.rooms == 1)
	// Unknown future targets remain forbidden, as do guest-to-guest messages.
	assert(network.send(&host, probe, new_peer + 1))
	packet = udp_test_client_event(&server, &host, .Error)
	testing.expect(t, packet.payload[0] == u8(network.Error_Code.Forbidden))
	assert(network.transport_queue(&replacement.transport, udp_test_data(departed_peer, 1)) && network.transport_flush(&replacement.transport))
	packet = udp_test_client_event(&server, &replacement, .Error)
	testing.expect(t, packet.payload[0] == u8(network.Error_Code.Forbidden) && server.stats.rejected == 2)
	testing.expect(t, host.status == .In_Room && replacement.status == .In_Room && server.stats.rooms == 1)
}

@(test)
relay_host_data_to_closing_admitted_peer_drops_but_future_target_remains_forbidden :: proc(t: ^testing.T) {
	server: Server
	assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
	defer server_stop(&server)
	host, guest := udp_test_connect(&server), udp_test_connect(&server)
	defer network.transport_close(&host)
	defer network.transport_close(&guest)
	udp_test_pair_room(&server)
	server.connections[1].closing = true
	server.connections[1].close_started = time.tick_now()
	assert(network.transport_queue(&host, udp_test_data(2, 1)) && network.transport_flush(&host))
	assert(server_update(&server))
	testing.expect(t, server.stats.rejected == 0 && server.stats.forwarded == 0 && !server.connections[0].closing)
	assert(network.transport_queue(&host, udp_test_data(3, 1)))
	packet := udp_test_tcp_read(&server, &host)
	testing.expect(t, packet.kind == .Error && packet.payload[0] == u8(network.Error_Code.Forbidden))
	testing.expect(t, server.stats.rejected == 1 && server.stats.rooms == 1)
}
