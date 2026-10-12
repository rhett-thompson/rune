package network

import "core:net"
import "core:testing"
import "core:time"

latency_test_client_pair :: proc() -> (Client, Transport, bool) {
	listener, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	if listen_error != nil {return {}, {}, false}
	defer net.close(listener)
	endpoint, endpoint_error := net.bound_endpoint(listener)
	if endpoint_error != nil {return {}, {}, false}
	client: Client
	if connect(&client, net.endpoint_to_string(endpoint)) != nil {return {}, {}, false}
	socket, _, accept_error := net.accept_tcp(listener)
	if accept_error != nil {disconnect(&client); return {}, {}, false}
	relay: Transport
	if !transport_init(&relay, socket) {disconnect(&client); return {}, {}, false}
	return client, relay, true
}

latency_test_receive :: proc(receiver: ^Transport) -> (Packet, bool) {
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		if !transport_receive(receiver) {return {}, false}
		packet, available, valid := transport_next(receiver)
		if !valid {return {}, false}
		if available {return packet, true}
		time.sleep(time.Millisecond)
	}
	return {}, false
}

@(test)
transport_enables_nodelay_on_dialed_and_accepted_sockets :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows || ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		sender, receiver, connected := transport_test_pair({no_delay = false})
		if !testing.expect(t, connected) {return}
		// Request sockets without the option: the test must distinguish Rune's
		// explicit setup from platforms where core:net normally enables it.
		for socket in ([]net.TCP_Socket{sender, receiver}) {
			enabled, measured := latency_test_nodelay(socket)
			testing.expect_value(t, measured, true)
			testing.expect_value(t, enabled, false)
		}
		client, relay: Transport
		defer transport_close(&client)
		defer transport_close(&relay)
		if !testing.expect(t, transport_init(&client, sender)) {net.close(receiver); return}
		if !testing.expect(t, transport_init(&relay, receiver)) {return}
		for socket in ([]net.TCP_Socket{client.socket, relay.socket}) {
			enabled, measured := latency_test_nodelay(socket)
			testing.expect(t, measured && enabled, "initialized movement sockets must disable Nagle")
		}
	}
}

@(test)
transport_configuration_failure_closes_owned_socket :: proc(t: ^testing.T) {
	// A live UDP socket accepts nonblocking setup but cannot accept a TCP-only
	// option. This exercises the option failure without an invalid OS handle.
	socket, error := net.create_socket(.IP4, .UDP)
	if !testing.expect(t, error == nil) {return}
	udp := socket.(net.UDP_Socket)
	assert(net.bind(udp, {net.IP4_Loopback, 0}) == nil)
	endpoint, endpoint_error := net.bound_endpoint(udp)
	assert(endpoint_error == nil)
	transport: Transport
	testing.expect(t, !transport_init(&transport, net.TCP_Socket(udp)))
	testing.expect(t, !transport.open)
	testing.expect_value(t, transport.send_count, 0)
	// Parallel tests can reuse a closed OS handle immediately. Verify release
	// through its exclusively bound port instead of querying that stale handle.
	probe, create_error := net.make_unbound_udp_socket(.IP4)
	if !testing.expect(t, create_error == nil) {return}
	defer net.close(probe)
	testing.expect(t, net.bind(probe, endpoint) == nil, "failed initialization must release its socket's bound port")
}

@(test)
client_send_delivers_movement_without_another_sender_poll :: proc(t: ^testing.T) {
	client, relay, connected := latency_test_client_pair()
	if !testing.expect(t, connected) {return}
	defer disconnect(&client)
	defer transport_close(&relay)
	client.status = .In_Room
	client.peer_id = 2
	input := [8]u8{1, 1, 0, 0, 0, 1, 1, 0}
	for target in ([]u32{1, 0, 3}) {
		client.is_host = target != 1
		testing.expect(t, send(&client, input[:], target))
		// Only the receiving side is pumped after send. The old queued-only API
		// leaves the peer empty until the game next polls the sending client.
		packet, received := latency_test_receive(&relay)
		if !testing.expect(t, received, "send should attempt delivery during the current simulation tick") {return}
		testing.expect_value(t, packet.kind, .Data)
		testing.expect_value(t, packet.peer, target)
		testing.expect_value(t, packet.payload_size, len(input))
		for value, index in input {testing.expect_value(t, packet.payload[index], value)}
	}
}

@(test)
client_rejected_send_produces_no_output :: proc(t: ^testing.T) {
	client, relay, connected := latency_test_client_pair()
	if !testing.expect(t, connected) {return}
	defer disconnect(&client)
	defer transport_close(&relay)
	payload := [1]u8{42}
	testing.expect(t, !send(nil, payload[:], 1))
	testing.expect(t, !send(&client, payload[:], 1), "connected clients must first join a room")
	client.status = .In_Room
	client.peer_id = 2
	testing.expect(t, !send(&client, payload[:], 0), "guests cannot broadcast")
	testing.expect(t, !send(&client, payload[:], 3), "guests cannot target another guest")
	oversized: [MAX_PAYLOAD + 1]u8
	testing.expect(t, !send(&client, oversized[:], 1))
	client.is_host = true
	testing.expect(t, !send(&client, payload[:], 1), "hosts cannot target themselves")
	testing.expect_value(t, client.transport.send_count, 0)
	testing.expect(t, transport_receive(&relay))
	_, available, valid := transport_next(&relay)
	testing.expect(t, valid && !available, "rejected messages must not reach the relay")
}

@(test)
client_fatal_immediate_send_disconnects :: proc(t: ^testing.T) {
	client, relay, connected := latency_test_client_pair()
	if !testing.expect(t, connected) {return}
	defer disconnect(&client)
	defer transport_close(&relay)
	client.status = .In_Room
	client.peer_id = 2
	if !testing.expect(t, net.shutdown(client.transport.socket, .Send) == nil) {return}
	payload := [1]u8{42}
	testing.expect(t, !send(&client, payload[:], 1))
	testing.expect_value(t, client.status, .Disconnected)
	testing.expect_value(t, client.peer_id, u32(0))
	testing.expect(t, !client.transport.open)
	testing.expect_value(t, client.transport.send_count, 0)
}
