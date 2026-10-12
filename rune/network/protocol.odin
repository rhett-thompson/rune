package network

// The TCP relay protocol uses a two-byte big-endian body length followed by
// RUNE, version, kind, peer ID, and an optional opaque application payload.
// Packet owns its payload so parsing another frame never invalidates an event.
PROTOCOL_VERSION :: u8(1)
MAX_PAYLOAD :: 1024
CODE_SIZE :: 16
MAX_ROOM_PEERS :: 8
FRAME_HEADER_SIZE :: 12
MIN_BODY_SIZE :: 10
MAX_BODY_SIZE :: MIN_BODY_SIZE + MAX_PAYLOAD
MAX_FRAME :: MAX_BODY_SIZE + 2

Kind :: enum u8 {
	Create      = 1,
	Join        = 2,
	Data        = 3,
	Leave       = 4,
	Ping        = 5,
	UDP_Enable  = 6,
	Welcome     = 16,
	Joined      = 17,
	Peer_Joined = 18,
	Peer_Left   = 19,
	Room_Closed = 20,
	Pong        = 21,
	Error       = 22,
	UDP_Session = 23,
}

Error_Code :: enum u8 {
	Invalid_Request = 1,
	Room_Not_Found  = 2,
	Room_Full       = 3,
	Server_Full     = 4,
	Not_In_Room     = 5,
	Forbidden       = 6,
	UDP_Unavailable = 7,
}

Packet :: struct {
	kind:         Kind,
	peer:         u32,
	payload:      [MAX_PAYLOAD]u8,
	payload_size: int,
}

kind_valid :: proc(kind: Kind) -> bool {
	#partial switch kind {
	case .Create, .Join, .Data, .Leave, .Ping, .UDP_Enable,
	     .Welcome, .Joined, .Peer_Joined, .Peer_Left, .Room_Closed, .Pong, .Error, .UDP_Session:
		return true
	}
	return false
}

room_code_valid :: proc(code: []u8) -> bool {
	if len(code) != CODE_SIZE { return false }
	for character in code {
		if !(character >= '0' && character <= '9') && !(character >= 'A' && character <= 'F') {
			return false
		}
	}
	return true
}

frame_encode :: proc(value: Packet, buffer: []u8) -> (size: int, valid: bool) {
	packet := value
	if !kind_valid(packet.kind) || packet.payload_size < 0 || packet.payload_size > MAX_PAYLOAD {
		return 0, false
	}
	body_size := MIN_BODY_SIZE + packet.payload_size
	size = body_size + 2
	if len(buffer) < size { return 0, false }
	buffer[0] = u8(body_size >> 8)
	buffer[1] = u8(body_size & 0xff)
	buffer[2] = 'R'
	buffer[3] = 'U'
	buffer[4] = 'N'
	buffer[5] = 'E'
	buffer[6] = PROTOCOL_VERSION
	buffer[7] = u8(packet.kind)
	buffer[8] = u8(packet.peer >> 24)
	buffer[9] = u8((packet.peer >> 16) & 0xff)
	buffer[10] = u8((packet.peer >> 8) & 0xff)
	buffer[11] = u8(packet.peer & 0xff)
	copy(buffer[FRAME_HEADER_SIZE:size], packet.payload[:packet.payload_size])
	return size, true
}

// consumed == 0 && valid means a complete frame has not arrived yet.
// Invalid lengths are rejected as soon as the two-byte prefix is available.
frame_decode :: proc(buffer: []u8) -> (packet: Packet, consumed: int, valid: bool) {
	if len(buffer) < 2 { return {}, 0, true }
	body_size := (int(buffer[0]) << 8) | int(buffer[1])
	if body_size < MIN_BODY_SIZE || body_size > MAX_BODY_SIZE { return {}, 0, false }
	frame_size := body_size + 2
	if len(buffer) < frame_size { return {}, 0, true }
	if buffer[2] != 'R' || buffer[3] != 'U' || buffer[4] != 'N' || buffer[5] != 'E' || buffer[6] != PROTOCOL_VERSION {
		return {}, 0, false
	}
	packet.kind = Kind(buffer[7])
	if !kind_valid(packet.kind) { return {}, 0, false }
	packet.peer = (u32(buffer[8]) << 24) | (u32(buffer[9]) << 16) | (u32(buffer[10]) << 8) | u32(buffer[11])
	packet.payload_size = body_size - MIN_BODY_SIZE
	copy(packet.payload[:packet.payload_size], buffer[FRAME_HEADER_SIZE:frame_size])
	return packet, frame_size, true
}
