package network

import "core:net"
import "core:testing"
import "core:time"

// Both sockets are blocking until a test transfers ownership to Transport.
transport_test_pair :: proc(options := net.DEFAULT_TCP_OPTIONS) -> (net.TCP_Socket, net.TCP_Socket, bool) {
	listener, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	if listen_error != nil { return {}, {}, false }
	defer net.close(listener)
	endpoint, endpoint_error := net.bound_endpoint(listener)
	if endpoint_error != nil { return {}, {}, false }
	sender, dial_error := net.dial_tcp(endpoint, options)
	if dial_error != nil { return {}, {}, false }
	receiver, _, accept_error := net.accept_tcp(listener, options)
	if accept_error != nil { net.close(sender); return {}, {}, false }
	return sender, receiver, true
}

transport_test_read_exact :: proc(socket: net.TCP_Socket, bytes: []u8) -> bool {
	count := 0
	for count < len(bytes) {
		read, error := net.recv_tcp(socket, bytes[count:])
		if error != nil || read == 0 { return false }
		count += read
	}
	return true
}

@(test)
transport_delivers_buffered_frames_before_remote_eof :: proc(t: ^testing.T) {
	sender, receiver, connected := transport_test_pair()
	if !testing.expect(t, connected) { return }
	defer net.close(sender)
	transport: Transport
	defer transport_close(&transport)
	packet := Packet{kind = .Data, peer = 1, payload_size = MAX_PAYLOAD}
	packet.payload[0] = 17
	bytes: [MAX_FRAME * 2]u8
	first_size, first_valid := frame_encode(packet, bytes[:])
	packet.payload[0] = 29
	second_size, second_valid := frame_encode(packet, bytes[first_size:])
	if !testing.expect(t, first_valid && second_valid) { net.close(receiver); return }
	written, send_error := net.send_tcp(sender, bytes[:first_size+second_size])
	if !testing.expect(t, send_error == nil && written == first_size+second_size) { net.close(receiver); return }
	testing.expect(t, net.shutdown(sender, .Send) == nil)
	// Gather exact bytes without assuming TCP coalesces the two writes or reads.
	// FIN is now pending behind complete frames already in the receive buffer.
	if !testing.expect(t, transport_test_read_exact(receiver, bytes[:first_size+second_size])) { net.close(receiver); return }
	if !testing.expect(t, transport_init(&transport, receiver)) { return }
	copy(transport.recv_buffer[:], bytes[:first_size+second_size])
	transport.recv_count = first_size+second_size
	for expected in ([2]u8{17, 29}) {
		testing.expect(t, transport_receive(&transport), "pending EOF must not discard a buffered frame")
		event, available, valid := transport_next(&transport)
		testing.expect(t, available && valid)
		testing.expect_value(t, event.payload[0], expected)
	}
	testing.expect(t, !transport_receive(&transport), "EOF is reported after buffered frames are consumed")
	testing.expect(t, transport.open, "the owner retains socket ownership after EOF")
}

@(test)
client_delivers_final_room_close_before_pending_output :: proc(t: ^testing.T) {
	sender, receiver, connected := transport_test_pair()
	if !testing.expect(t, connected) { return }
	defer net.close(sender)
	client: Client
	defer disconnect(&client)
	bytes: [MAX_FRAME * 2]u8
	packet := Packet{kind = .Data, peer = 1, payload_size = 1}
	packet.payload[0] = 71
	first_size, first_valid := frame_encode(packet, bytes[:])
	second_size, second_valid := frame_encode(Packet{kind = .Room_Closed}, bytes[first_size:])
	if !testing.expect(t, first_valid && second_valid) { net.close(receiver); return }
	written, send_error := net.send_tcp(sender, bytes[:first_size+second_size])
	if !testing.expect(t, send_error == nil && written == first_size+second_size) { net.close(receiver); return }
	testing.expect(t, net.shutdown(sender, .Send) == nil)
	if !testing.expect(t, transport_test_read_exact(receiver, bytes[:first_size+second_size])) { net.close(receiver); return }
	if !testing.expect(t, transport_init(&client.transport, receiver)) { return }
	client.status = .In_Room
	client.peer_id = 2
	client.last_received = time.tick_now()
	client.last_ping = client.last_received
	copy(client.transport.recv_buffer[:], bytes[:first_size+second_size])
	client.transport.recv_count = first_size+second_size
	// A previous nonblocking send may have left application data queued.
	// Queue it explicitly so this regression retains pending output even when
	// send normally delivers small movement frames immediately.
	input := Packet{kind = .Data, peer = 1, payload_size = 1}
	input.payload[0] = 42
	testing.expect(t, transport_queue(&client.transport, input))
	pending := client.transport.send_count
	testing.expect(t, pending > 0)
	event, available, good := poll(&client)
	testing.expect(t, available && good && event.kind == .Data)
	testing.expect_value(t, event.payload[0], u8(71))
	testing.expect(t, client.transport.send_count == pending, "receiving a final event takes priority over pending output")
	closed, closed_available, closed_good := poll(&client)
	testing.expect(t, closed_available && closed_good && closed.kind == .Room_Closed)
	testing.expect_value(t, client.status, .Disconnected)
	testing.expect_value(t, client.peer_id, u32(0))
	testing.expect(t, !client.transport.open)
}
