package network

import "core:testing"

@(test)
udp_datagram_wire_fixture_and_shared_frame_compatibility :: proc(t: ^testing.T) {
	fixture := [41]u8{
		'R', 'U', 'N', 'E', 2, 3,
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
		0x01, 0x23, 0x45, 0x67,
		0, 13, 'R', 'U', 'N', 'E', 1, 3, 1, 2, 3, 4, 0, 127, 255,
	}
	value, valid := udp_decode(fixture[:])
	testing.expect(t, valid && value.kind == .Data && value.sequence == 0x01234567)
	testing.expect(t, value.packet.kind == .Data && value.packet.peer == 0x01020304 && value.packet.payload_size == 3 && value.packet.payload[2] == 255)
	for byte, index in value.token {testing.expect_value(t, byte, u8(index+1))}
	buffer: [UDP_MAX_DATAGRAM_SIZE+1]u8
	size, encoded := udp_encode(value, buffer[:])
	testing.expect(t, encoded && size == len(fixture))
	for byte, index in fixture {testing.expect_value(t, buffer[index], byte)}
	for cut in 0..<len(fixture) {_, ok := udp_decode(fixture[:cut]); testing.expect(t, !ok, "truncated datagrams cannot become partial stream events")}
	_, valid = udp_decode(buffer[:size+1])
	testing.expect(t, !valid, "a datagram contains exactly one complete shared frame")
	for index in ([]int{0, 1, 2, 3, 4, 5, UDP_HEADER_SIZE+7}) {
		bad := fixture
		bad[index] = 255
		_, valid = udp_decode(bad[:])
		testing.expect(t, !valid, "magic, version, type, and inner Data kind are checked")
	}
	bad := fixture
	for index in 6..<22 {bad[index] = 0}
	_, valid = udp_decode(bad[:])
	testing.expect(t, !valid, "zero tokens cannot authenticate a UDP session")
	value.packet.kind = .Ping
	_, encoded = udp_encode(value, buffer[:])
	testing.expect(t, !encoded, "room and lifecycle controls remain on TCP")
}

@(test)
udp_binding_headers_and_maximum_payload_are_bounded :: proc(t: ^testing.T) {
	token: [UDP_TOKEN_SIZE]u8
	token[0] = 123
	buffer: [UDP_MAX_DATAGRAM_SIZE+1]u8
	for kind in ([]UDP_Datagram_Kind{.Bind, .Bind_Ack}) {
		value := UDP_Datagram{kind = kind, token = token, sequence = 0xffffffff}
		size, encoded := udp_encode(value, buffer[:])
		decoded, valid := udp_decode(buffer[:size])
		testing.expect(t, encoded && valid && size == UDP_HEADER_SIZE && decoded == value)
		_, valid = udp_decode(buffer[:size+1])
		testing.expect(t, !valid, "bind messages have no trailing application frame")
	}
	value := UDP_Datagram{kind = .Data, token = token, packet = {kind = .Data, peer = 1, payload_size = MAX_PAYLOAD}}
	value.packet.payload[MAX_PAYLOAD-1] = 231
	size, encoded := udp_encode(value, buffer[:])
	decoded, valid := udp_decode(buffer[:size])
	testing.expect(t, encoded && valid && size == UDP_MAX_DATAGRAM_SIZE && size < 1200 && decoded == value)
	_, valid = udp_decode(buffer[:])
	testing.expect(t, !valid, "oversized datagrams are rejected")
	_, encoded = udp_encode(value, buffer[:size-1])
	testing.expect(t, !encoded)
	for count in ([]int{-1, MAX_PAYLOAD+1}) {
		value.packet.payload_size = count
		_, encoded = udp_encode(value, buffer[:])
		testing.expect(t, !encoded)
	}
	_, encoded = udp_encode({kind = .Bind}, buffer[:])
	testing.expect(t, !encoded)
}

@(test)
udp_replay_window_accepts_reordering_without_duplicates_or_old_replays :: proc(t: ^testing.T) {
	window: Replay_Window
	testing.expect(t, !udp_replay_accept(nil, 1))
	testing.expect(t, udp_replay_accept(&window, 80))
	testing.expect(t, udp_replay_accept(&window, 78) && udp_replay_accept(&window, 79))
	testing.expect(t, !udp_replay_accept(&window, 80) && !udp_replay_accept(&window, 78))
	testing.expect(t, udp_replay_accept(&window, 17), "63 places of reordering remain in the window")
	testing.expect(t, !udp_replay_accept(&window, 16), "64 places of reordering are expired")
	testing.expect(t, udp_replay_accept(&window, 200) && window.bits == 1, "a large jump clears expired history")
	testing.expect(t, !udp_replay_accept(&window, 80))
	before := window
	testing.expect(t, !udp_replay_accept(&window, 200+0x80000000) && window == before, "ambiguous half-range serials leave the window intact")
	window = {}
	testing.expect(t, udp_replay_accept(&window, 0xfffffffd) && udp_replay_accept(&window, 1))
	testing.expect(t, udp_replay_accept(&window, 0) && udp_replay_accept(&window, 0xfffffffe))
	testing.expect(t, !udp_replay_accept(&window, 0xfffffffd) && !udp_replay_accept(&window, 0), "duplicates remain rejected across sequence wrap")
}
