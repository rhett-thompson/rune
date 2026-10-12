package network

import "core:net"
import "core:testing"
import "core:time"

UDP_Test_Fixture :: struct {
	client: Client,
	relay: Transport,
	socket: net.UDP_Socket,
	open: bool,
	token: [UDP_TOKEN_SIZE]u8,
	client_endpoint: net.Endpoint,
	bind_sequence: u32,
}

udp_test_cleanup :: proc(fixture: ^UDP_Test_Fixture) {
	disconnect(&fixture.client)
	transport_close(&fixture.relay)
	if fixture.open {net.close(fixture.socket); fixture.open = false}
}

udp_test_start :: proc(fixture: ^UDP_Test_Fixture) {
	listener, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	assert(listen_error == nil)
	defer net.close(listener)
	endpoint, endpoint_error := net.bound_endpoint(listener)
	assert(endpoint_error == nil)
	fixture.socket, listen_error = net.make_unbound_udp_socket(.IP4)
	assert(listen_error == nil)
	fixture.open = true
	assert(net.bind(fixture.socket, endpoint) == nil && net.set_blocking(fixture.socket, false) == nil)
	assert(connect(&fixture.client, net.endpoint_to_string(endpoint), use_udp = true) == nil)
	socket, _, accept_error := net.accept_tcp(listener)
	assert(accept_error == nil && transport_init(&fixture.relay, socket))
	request, received := latency_test_receive(&fixture.relay)
	assert(received && request.kind == .UDP_Enable && request.payload_size == 0 && request.peer == 0)
	fixture.client.status, fixture.client.peer_id, fixture.client.is_host = .In_Room, 2, false
	for &byte, index in fixture.token {byte = u8(index+1)}
}

udp_test_send :: proc(socket: net.UDP_Socket, endpoint: net.Endpoint, value: UDP_Datagram) {
	buffer: [UDP_MAX_DATAGRAM_SIZE]u8
	size, encoded := udp_encode(value, buffer[:])
	assert(encoded)
	written, error := net.send_udp(socket, buffer[:size], endpoint)
	assert(error == nil && written == size)
}

udp_test_receive :: proc(socket: net.UDP_Socket) -> (UDP_Datagram, net.Endpoint) {
	buffer: [UDP_MAX_DATAGRAM_SIZE+1]u8
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		read, endpoint, error := net.recv_udp(socket, buffer[:])
		if error == .Would_Block || error == .Interrupted {time.sleep(time.Millisecond); continue}
		assert(error == nil)
		value, valid := udp_decode(buffer[:read])
		assert(valid)
		return value, endpoint
	}
	assert(false, "expected UDP datagram did not arrive")
	return {}, {}
}

udp_test_negotiate_token :: proc(fixture: ^UDP_Test_Fixture) {
	packet := Packet{kind = .UDP_Session, payload_size = UDP_TOKEN_SIZE}
	copy(packet.payload[:UDP_TOKEN_SIZE], fixture.token[:])
	assert(transport_queue(&fixture.relay, packet) && transport_flush(&fixture.relay))
	started := time.tick_now()
	for !fixture.client.udp_session && time.tick_since(started) < time.Second {
		_, available, ok := poll(&fixture.client)
		assert(ok && !available)
		time.sleep(time.Millisecond)
	}
	assert(fixture.client.udp_session)
	bind, source := udp_test_receive(fixture.socket)
	assert(bind.kind == .Bind && bind.token == fixture.token)
	fixture.client_endpoint, fixture.bind_sequence = source, bind.sequence
}

udp_test_wait_rejected :: proc(client: ^Client, count: u64) {
	started := time.tick_now()
	for client.udp_datagrams_rejected < count && time.tick_since(started) < time.Second {
		_, available, ok := poll(client)
		assert(ok && !available)
		time.sleep(time.Millisecond)
	}
	assert(client.udp_datagrams_rejected >= count)
}

udp_test_ack :: proc(fixture: ^UDP_Test_Fixture) {
	udp_test_send(fixture.socket, fixture.client_endpoint, {kind = .Bind_Ack, token = fixture.token, sequence = fixture.bind_sequence})
	started := time.tick_now()
	for !fixture.client.udp_ready && time.tick_since(started) < time.Second {
		_, available, ok := poll(&fixture.client)
		assert(ok && !available)
		time.sleep(time.Millisecond)
	}
	assert(fixture.client.udp_ready)
}

udp_test_expect_data :: proc(fixture: ^UDP_Test_Fixture, sequence: u32) {
	packet := Packet{kind = .Data, peer = 1, payload_size = 1}
	packet.payload[0] = u8(sequence)
	udp_test_send(fixture.socket, fixture.client_endpoint, {kind = .Data, token = fixture.token, sequence = sequence, packet = packet})
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		value, available, ok := poll(&fixture.client)
		assert(ok)
		if available {assert(value.kind == .Data && value.peer == 1 && value.payload_size == 1 && value.payload[0] == u8(sequence)); return}
		time.sleep(time.Millisecond)
	}
	assert(false, "expected authenticated UDP gameplay event did not arrive")
}

@(test)
client_udp_requires_authenticated_binding_then_sends_gameplay_without_tcp :: proc(t: ^testing.T) {
	fixture: UDP_Test_Fixture
	defer udp_test_cleanup(&fixture)
	udp_test_start(&fixture)
	udp_test_negotiate_token(&fixture)
	testing.expect(t, fixture.client.udp_requested && !fixture.client.udp_ready && !fixture.client.udp_failed)
	// Startup gameplay can use TCP until binding is confirmed.
	payload := [1]u8{42}
	testing.expect(t, send(&fixture.client, payload[:], 1))
	startup, received := latency_test_receive(&fixture.relay)
	testing.expect(t, received && startup.kind == .Data && fixture.client.udp_datagrams_sent == 0)
	rogue, error := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	assert(error == nil)
	defer net.close(rogue)
	udp_test_send(rogue, fixture.client_endpoint, {kind = .Bind_Ack, token = fixture.token, sequence = fixture.bind_sequence})
	udp_test_wait_rejected(&fixture.client, 1)
	testing.expect(t, !fixture.client.udp_ready, "another UDP source cannot impersonate the TCP relay")
	bad_token := fixture.token
	bad_token[0] = 255
	udp_test_send(fixture.socket, fixture.client_endpoint, {kind = .Bind_Ack, token = bad_token, sequence = fixture.bind_sequence})
	udp_test_wait_rejected(&fixture.client, 2)
	testing.expect(t, !fixture.client.udp_ready, "the negotiated token is required even from the correct endpoint")
	udp_test_ack(&fixture)
	testing.expect(t, send(&fixture.client, payload[:], 1))
	data, source := udp_test_receive(fixture.socket)
	testing.expect(t, data.kind == .Data && data.token == fixture.token && data.packet.kind == .Data && data.packet.peer == 1 &&
		data.packet.payload[0] == 42 && udp_endpoint_equal(source, fixture.client_endpoint))
	testing.expect_value(t, fixture.client.udp_datagrams_sent, u64(1))
	testing.expect(t, transport_receive(&fixture.relay))
	_, available, valid := transport_next(&fixture.relay)
	testing.expect(t, valid && !available, "bound gameplay does not also travel over TCP")
}

@(test)
client_udp_filters_endpoint_token_sender_and_replayed_datagrams :: proc(t: ^testing.T) {
	fixture: UDP_Test_Fixture
	defer udp_test_cleanup(&fixture)
	udp_test_start(&fixture)
	udp_test_negotiate_token(&fixture)
	udp_test_ack(&fixture)
	udp_test_expect_data(&fixture, 10)
	udp_test_expect_data(&fixture, 8)
	udp_test_expect_data(&fixture, 9)
	duplicate := UDP_Datagram{kind = .Data, token = fixture.token, sequence = 10, packet = {kind = .Data, peer = 1, payload_size = 1}}
	udp_test_send(fixture.socket, fixture.client_endpoint, duplicate)
	udp_test_wait_rejected(&fixture.client, 1)
	bad := duplicate
	bad.sequence, bad.token[0] = 11, 255
	udp_test_send(fixture.socket, fixture.client_endpoint, bad)
	udp_test_wait_rejected(&fixture.client, 2)
	udp_test_expect_data(&fixture, 11)
	bad = duplicate
	bad.sequence, bad.packet.peer = 12, fixture.client.peer_id
	udp_test_send(fixture.socket, fixture.client_endpoint, bad)
	udp_test_wait_rejected(&fixture.client, 3)
	udp_test_expect_data(&fixture, 12)
	oversized: [UDP_MAX_DATAGRAM_SIZE+100]u8
	written, send_error := net.send_udp(fixture.socket, oversized[:], fixture.client_endpoint)
	assert(send_error == nil && written == len(oversized))
	udp_test_wait_rejected(&fixture.client, 4)
	udp_test_expect_data(&fixture, 13)
	testing.expect_value(t, fixture.client.udp_datagrams_received, u64(6))
	testing.expect(t, fixture.client.udp_ready && !fixture.client.udp_failed, "unauthenticated or duplicate datagrams cannot destroy a healthy session")
}

@(test)
client_udp_retries_binding_and_accepts_an_authenticated_delayed_ack :: proc(t: ^testing.T) {
	fixture: UDP_Test_Fixture
	defer udp_test_cleanup(&fixture)
	udp_test_start(&fixture)
	udp_test_negotiate_token(&fixture)
	first_sequence := fixture.bind_sequence
	fixture.client.udp_last_bind = time.tick_add(time.tick_now(), -UDP_BIND_RETRY_INTERVAL)
	_, available, ok := poll(&fixture.client)
	assert(ok && !available)
	for {
		bind, source := udp_test_receive(fixture.socket)
		assert(bind.kind == .Bind && bind.token == fixture.token && udp_endpoint_equal(source, fixture.client_endpoint))
		if bind.sequence == fixture.client.udp_bind_sequence {break}
	}
	testing.expect(t, fixture.client.udp_bind_sequence != first_sequence && !fixture.client.udp_ready)
	// An earlier bind's acknowledgement may arrive after the retry was sent.
	fixture.bind_sequence = first_sequence
	udp_test_ack(&fixture)
	testing.expect(t, fixture.client.udp_ready && !fixture.client.udp_failed)
}

@(test)
client_udp_negotiation_deadline_and_unavailable_are_terminal :: proc(t: ^testing.T) {
	for unavailable in ([2]bool{false, true}) {
		fixture: UDP_Test_Fixture
		defer udp_test_cleanup(&fixture)
		udp_test_start(&fixture)
		if unavailable {
			packet := Packet{kind = .Error, payload_size = 1}
			packet.payload[0] = u8(Error_Code.UDP_Unavailable)
			assert(transport_queue(&fixture.relay, packet) && transport_flush(&fixture.relay))
		} else {
			fixture.client.udp_started = time.tick_add(time.tick_now(), -UDP_NEGOTIATION_TIMEOUT-time.Second)
		}
		started := time.tick_now()
		ok := true
		for ok && time.tick_since(started) < time.Second {_, _, ok = poll(&fixture.client); if ok {time.sleep(time.Millisecond)}}
		testing.expect(t, !ok && fixture.client.udp_failed && fixture.client.udp_requested && !fixture.client.udp_ready &&
			!fixture.client.udp_open && !fixture.client.transport.open && fixture.client.status == .Disconnected,
			"requested UDP cannot silently remain on TCP after negotiation fails")
	}
}

@(test)
client_tcp_room_closure_precedes_buffered_udp_gameplay :: proc(t: ^testing.T) {
	fixture: UDP_Test_Fixture
	defer udp_test_cleanup(&fixture)
	udp_test_start(&fixture)
	udp_test_negotiate_token(&fixture)
	udp_test_ack(&fixture)
	udp_test_send(fixture.socket, fixture.client_endpoint, {kind = .Data, token = fixture.token, sequence = 1, packet = {kind = .Data, peer = 1}})
	assert(transport_queue(&fixture.relay, Packet{kind = .Room_Closed}) && transport_flush(&fixture.relay))
	// Ensure the control is already buffered before the poll under test.
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		assert(transport_receive(&fixture.client.transport))
		_, consumed, valid := frame_decode(fixture.client.transport.recv_buffer[:fixture.client.transport.recv_count])
		assert(valid)
		if consumed > 0 {break}
		time.sleep(time.Millisecond)
	}
	fixture.client.udp_last_received = time.tick_add(time.tick_now(), -CLIENT_TIMEOUT-time.Second)
	packet, available, ok := poll(&fixture.client)
	testing.expect(t, ok && available && packet.kind == .Room_Closed && fixture.client.status == .Disconnected &&
		!fixture.client.udp_open && !fixture.client.udp_ready && fixture.client.udp_datagrams_received == 0,
		"reliable room teardown closes both transports before delivering queued movement")
}
