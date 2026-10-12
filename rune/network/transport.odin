package network

import "core:net"
import "core:time"

// All storage is bounded. A slow peer must not retain unlimited relay traffic.
Transport :: struct {
	socket:      net.TCP_Socket,
	open:        bool,
	recv_buffer: [MAX_FRAME * 2]u8,
	recv_count:  int,
	send_buffer: [MAX_FRAME * 64]u8,
	send_count:  int,
	send_frame_remaining: int,
	send_frame_kind: Kind,
	traffic: Traffic_Meter,
	last_ping_sent: time.Tick,
}

// Takes ownership of socket, including when configuring the socket fails.
transport_init :: proc(transport: ^Transport, socket: net.TCP_Socket) -> bool {
	if transport == nil { net.close(socket); return false }
	transport_close(transport)
	transport.traffic, transport.last_ping_sent = {}, {}
	transport.socket = socket
	// Some core:net platform backends omit the default no-delay option.
	// Movement frames must not wait for unrelated small writes to be acknowledged.
	if net.set_blocking(socket, false) != nil || net.set_option(socket, .TCP_Nodelay, true) != nil {
		net.close(socket)
		transport.socket = {}
		return false
	}
	transport.open = true
	return true
}

transport_close :: proc(transport: ^Transport) {
	if transport == nil { return }
	if transport.open { net.close(transport.socket) }
	transport.open = false
	transport.socket = {}
	transport.recv_count = 0
	transport.send_count = 0
	transport.send_frame_remaining = 0
	transport.send_frame_kind = {}
}

// Queues a complete frame; no socket operation occurs here.
transport_queue :: proc(transport: ^Transport, packet: Packet) -> bool {
	if transport == nil || !transport.open { return false }
	size, valid := frame_encode(packet, transport.send_buffer[transport.send_count:])
	if !valid { return false }
	transport.send_count += size
	return true
}

// core:net.send_tcp reports bytes already sent even if the socket would block.
// Preserve the remainder and retry it on the next pump.
transport_flush :: proc(transport: ^Transport) -> bool {
	if transport == nil || !transport.open { return false }
	if transport.send_count == 0 { return true }
	written, error := net.send_tcp(transport.socket, transport.send_buffer[:transport.send_count])
	if written < 0 || written > transport.send_count { return false }
	if written > 0 {
		now := time.tick_now()
		completed := transport_count_sent_frames(transport, written, now)
		traffic_record(&transport.traffic, {tx_bytes = u64(written), tx_packets = completed}, now)
		copy(transport.send_buffer[:transport.send_count-written], transport.send_buffer[written:transport.send_count])
		transport.send_count -= written
	}
	if error != nil && error != .Would_Block && error != .Interrupted {
		return false
	}
	return true
}

// Reads at most once. Call transport_next to consume buffered complete frames
// before receiving again, keeping both receive work and storage bounded.
transport_receive :: proc(transport: ^Transport) -> bool {
	if transport == nil || !transport.open { return false }
	// Drain complete or malformed buffered frames before reading again. Besides
	// bounding storage, this preserves already-received events when EOF follows.
	_, consumed, valid := frame_decode(transport.recv_buffer[:transport.recv_count])
	if consumed > 0 || !valid { return true }
	if transport.recv_count == len(transport.recv_buffer) { return false }
	read, error := net.recv_tcp(transport.socket, transport.recv_buffer[transport.recv_count:])
	if error == .Would_Block || error == .Interrupted { return true }
	if error != nil || read <= 0 || read > len(transport.recv_buffer)-transport.recv_count {
		return false
	}
	transport.recv_count += read
	traffic_record(&transport.traffic, {rx_bytes = u64(read)}, time.tick_now())
	return true
}

transport_next :: proc(transport: ^Transport) -> (packet: Packet, available: bool, valid: bool) {
	if transport == nil || !transport.open { return {}, false, false }
	consumed: int
	packet, consumed, valid = frame_decode(transport.recv_buffer[:transport.recv_count])
	if !valid { return {}, false, false }
	if consumed == 0 { return {}, false, true }
	copy(transport.recv_buffer[:transport.recv_count-consumed], transport.recv_buffer[consumed:transport.recv_count])
	transport.recv_count -= consumed
	traffic_record(&transport.traffic, {rx_packets = 1}, time.tick_now())
	return packet, true, true
}

@(private="package")
transport_count_sent_frames :: proc(transport: ^Transport, written: int, now: time.Tick) -> u64 {
	completed: u64
	cursor := 0
	for cursor < written {
		if transport.send_frame_remaining == 0 {
			// Queued frames are complete. Only the first may already be partial,
			// in which case its remaining count and kind were retained earlier.
			transport.send_frame_remaining = 2 + (int(transport.send_buffer[cursor])<<8) + int(transport.send_buffer[cursor+1])
			transport.send_frame_kind = Kind(transport.send_buffer[cursor+7])
		}
		step := min(written-cursor, transport.send_frame_remaining)
		transport.send_frame_remaining -= step
		cursor += step
		if transport.send_frame_remaining == 0 {
			completed += 1
			if transport.send_frame_kind == .Ping {transport.last_ping_sent = now}
		}
	}
	return completed
}
