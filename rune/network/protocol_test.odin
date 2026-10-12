package network

import "core:testing"

@(test)
protocol_interoperable_frame_and_stream_boundaries :: proc(t: ^testing.T) {
	// A wire fixture independent of the encoder: target/sender 0x01020304,
	// three binary bytes (including a zero) in a version-one Data frame.
	fixture := [15]u8{0, 13, 'R', 'U', 'N', 'E', 1, 3, 1, 2, 3, 4, 0, 127, 255}
	for split in 0..<len(fixture) {
		_, used, valid := frame_decode(fixture[:split])
		testing.expect(t, valid && used == 0)
	}
	packet, used, valid := frame_decode(fixture[:])
	testing.expect(t, valid && used == len(fixture))
	testing.expect_value(t, packet.kind, .Data)
	testing.expect_value(t, packet.peer, u32(0x01020304))
	testing.expect_value(t, packet.payload_size, 3)
	testing.expect_value(t, packet.payload[2], u8(255))
	buffer: [MAX_FRAME]u8
	written, encoded := frame_encode(packet, buffer[:])
	testing.expect(t, encoded && written == len(fixture))
	for value, index in fixture {testing.expect_value(t, buffer[index], value)}
	// Two coalesced frames must produce distinct, owned payloads. Parsing the
	// second event and shifting the receive buffer cannot invalidate the first.
	transport := Transport{open = true}
	copy(transport.recv_buffer[:], fixture[:])
	copy(transport.recv_buffer[len(fixture):], fixture[:])
	transport.recv_buffer[len(fixture) + 12] = 42
	transport.recv_count = 2 * len(fixture)
	first, available, good := transport_next(&transport)
	testing.expect(t, available && good)
	second, another, good_second := transport_next(&transport)
	testing.expect(t, another && good_second)
	testing.expect_value(t, first.payload[0], u8(0))
	testing.expect_value(t, second.payload[0], u8(42))
	testing.expect_value(t, transport.recv_count, 0)
}

@(test)
protocol_rejects_malformed_and_oversized_frames :: proc(t: ^testing.T) {
	for prefix in ([][2]u8{{0, 0}, {0, 9}, {4, 11}, {255, 255}}) {
		buffer := prefix
		_, _, valid := frame_decode(buffer[:])
		testing.expect(t, !valid)
	}
	fixture := [12]u8{0, 10, 'R', 'U', 'N', 'E', 1, 5, 0, 0, 0, 0}
	for offset in ([]int{2, 3, 4, 5, 6, 7}) {
		invalid := fixture
		invalid[offset] = 255
		_, _, valid := frame_decode(invalid[:])
		testing.expect(t, !valid)
	}
	buffer: [MAX_FRAME]u8
	packet := Packet{kind = .Data, payload_size = MAX_PAYLOAD}
	packet.payload[MAX_PAYLOAD - 1] = 231
	size, valid := frame_encode(packet, buffer[:])
	testing.expect(t, valid && size == MAX_FRAME)
	decoded, consumed, decoded_valid := frame_decode(buffer[:])
	testing.expect(t, decoded_valid && consumed == MAX_FRAME)
	testing.expect_value(t, decoded.payload[MAX_PAYLOAD - 1], u8(231))
	for count in ([]int{-1, MAX_PAYLOAD + 1}) {
		packet.payload_size = count
		_, encoded := frame_encode(packet, buffer[:])
		testing.expect(t, !encoded)
	}
	packet.payload_size = MAX_PAYLOAD
	_, fits := frame_encode(packet, buffer[:MAX_FRAME - 1])
	testing.expect(t, !fits)
}

@(test)
transport_queue_is_bounded_and_failed_append_preserves_frames :: proc(t: ^testing.T) {
	transport := Transport{open = true}
	packet := Packet{kind = .Data, payload_size = MAX_PAYLOAD, peer = 1}
	for i in 0..<64 {
		packet.payload[0] = u8(i)
		testing.expect(t, transport_queue(&transport, packet))
	}
	testing.expect(t, !transport_queue(&transport, packet))
	testing.expect_value(t, transport.send_count, 64 * MAX_FRAME)
	for i in 0..<64 {
		frame, consumed, valid := frame_decode(transport.send_buffer[i * MAX_FRAME:(i + 1) * MAX_FRAME])
		testing.expect(t, valid && consumed == MAX_FRAME)
		testing.expect_value(t, frame.payload[0], u8(i))
	}
}
