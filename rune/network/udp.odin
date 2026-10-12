package network

import "core:net"

UDP_PROTOCOL_VERSION :: u8(2)
UDP_TOKEN_SIZE :: 16
UDP_HEADER_SIZE :: 26
UDP_MAX_DATAGRAM_SIZE :: UDP_HEADER_SIZE + MAX_FRAME
#assert(UDP_MAX_DATAGRAM_SIZE < 1200)

UDP_Datagram_Kind :: enum u8 {Bind = 1, Bind_Ack = 2, Data = 3}
UDP_Datagram :: struct {
	kind: UDP_Datagram_Kind,
	token: [UDP_TOKEN_SIZE]u8,
	sequence: u32,
	packet: Packet,
}

udp_token_valid :: proc(token: [UDP_TOKEN_SIZE]u8) -> bool {
	for byte in token {if byte != 0 {return true}}
	return false
}

udp_endpoint_equal :: proc(left, right: net.Endpoint) -> bool {
	return left.port == right.port && left.address == right.address
}

udp_encode :: proc(value: UDP_Datagram, buffer: []u8) -> (int, bool) {
	value := value
	if len(buffer) < UDP_HEADER_SIZE || !udp_token_valid(value.token) {return 0, false}
	size := UDP_HEADER_SIZE
	switch value.kind {
	case .Bind, .Bind_Ack:
	case .Data:
		if value.packet.kind != .Data {return 0, false}
		written, valid := frame_encode(value.packet, buffer[UDP_HEADER_SIZE:])
		if !valid {return 0, false}
		size += written
	case: return 0, false
	}
	buffer[0], buffer[1], buffer[2], buffer[3] = 'R', 'U', 'N', 'E'
	buffer[4], buffer[5] = UDP_PROTOCOL_VERSION, u8(value.kind)
	copy(buffer[6:22], value.token[:])
	buffer[22] = u8(value.sequence >> 24)
	buffer[23] = u8((value.sequence >> 16) & 0xff)
	buffer[24] = u8((value.sequence >> 8) & 0xff)
	buffer[25] = u8(value.sequence & 0xff)
	return size, true
}

udp_decode :: proc(buffer: []u8) -> (UDP_Datagram, bool) {
	if len(buffer) < UDP_HEADER_SIZE || len(buffer) > UDP_MAX_DATAGRAM_SIZE ||
	   buffer[0] != 'R' || buffer[1] != 'U' || buffer[2] != 'N' || buffer[3] != 'E' ||
	   buffer[4] != UDP_PROTOCOL_VERSION {return {}, false}
	value := UDP_Datagram{kind = UDP_Datagram_Kind(buffer[5])}
	copy(value.token[:], buffer[6:22])
	if !udp_token_valid(value.token) {return {}, false}
	value.sequence = (u32(buffer[22]) << 24) | (u32(buffer[23]) << 16) | (u32(buffer[24]) << 8) | u32(buffer[25])
	switch value.kind {
	case .Bind, .Bind_Ack:
		if len(buffer) != UDP_HEADER_SIZE {return {}, false}
	case .Data:
		packet, consumed, valid := frame_decode(buffer[UDP_HEADER_SIZE:])
		if !valid || consumed != len(buffer)-UDP_HEADER_SIZE || consumed == 0 || packet.kind != .Data {return {}, false}
		value.packet = packet
	case: return {}, false
	}
	return value, true
}

Replay_Window :: struct {
	latest: u32,
	has_latest: bool,
	bits: u64,
	span: u32,
	finalized_expected, finalized_received, finalized_lost: u64,
}

// Accept each datagram once while allowing up to 63 places of reordering.
// Comparisons remain valid across wrap, excluding the ambiguous half-range.
udp_replay_accept :: proc(window: ^Replay_Window, sequence: u32) -> bool {
	if window == nil {return false}
	if !window.has_latest {window^ = {latest = sequence, has_latest = true, bits = 1, span = 1}; return true}
	distance := sequence - window.latest
	if i32(distance) > 0 {
		span := window.span
		if span == 0 || span > 64 {span = 64} // Preserve callers' older three-field initializers.
		finalized := u64(max(i64(span)+i64(distance)-64, 0))
		expired_bits := window.bits if distance >= 64 else window.bits >> (64-distance)
		received: u64
		for expired_bits != 0 {received += 1; expired_bits &= expired_bits-1}
		window.finalized_expected += finalized
		window.finalized_received += received
		window.finalized_lost += finalized-received
		window.span = min(span+distance, 64)
		window.bits = 1 if distance >= 64 else (window.bits << distance) | 1
		window.latest = sequence
		return true
	}
	age := window.latest - sequence
	if age >= 64 {return false}
	mask := u64(1) << age
	if window.bits & mask != 0 {return false}
	window.bits |= mask
	window.span = max(window.span, age+1)
	return true
}
