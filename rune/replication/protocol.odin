package replication

import "core:math"
import "rune:network"

// Application payloads carried by network.Data. Entity IDs belong to the host
// and are independent of each client's World-local ECS handles.
MAX_ENTITIES :: network.MAX_ROOM_PEERS
PROTOCOL_VERSION :: u8(1)
INPUT_KIND :: u8(1)
SNAPSHOT_KIND :: u8(2)
INPUT_SIZE :: 8
SNAPSHOT_HEADER_SIZE :: 7
STATE_SIZE :: 16
MAX_SNAPSHOT_SIZE :: SNAPSHOT_HEADER_SIZE + STATE_SIZE * MAX_ENTITIES

Identity :: struct {
	id:         u32,
	owner_peer: u32,
}

State :: struct {
	id:         u32,
	owner_peer: u32,
	position:   [2]f32,
}

Snapshot :: struct {
	tick:   u32,
	count:  int,
	states: [MAX_ENTITIES]State,
}

// Commands sample held input. The host applies the latest accepted sample once
// per fixed simulation step, never once per received packet.
Input_Command :: struct {
	sequence: u32,
	axis:     [2]i8,
}

input_valid :: proc(value: Input_Command) -> bool {
	for axis in value.axis {if axis < -1 || axis > 1 {return false}}
	return true
}

snapshot_valid :: proc(value: Snapshot) -> bool {
	value := value
	if value.count < 0 || value.count > MAX_ENTITIES {return false}
	for state, index in value.states[:value.count] {
		if state.id == 0 || state.owner_peer == 0 {return false}
		for axis in state.position {if math.is_nan(axis) || math.is_inf(axis) {return false}}
		for previous in value.states[:index] {if previous.id == state.id {return false}}
	}
	return true
}

// Serial numbers may wrap. Equal values and the ambiguous half-range distance
// are rejected; callers must not retain a sample for 2^31 sequence increments.
sequence_newer :: proc(candidate, previous: u32) -> bool {
	return i32(candidate - previous) > 0
}

encode_input :: proc(value: Input_Command, buffer: []u8) -> (size: int, valid: bool) {
	if !input_valid(value) || len(buffer) < INPUT_SIZE {return 0, false}
	buffer[0] = PROTOCOL_VERSION
	buffer[1] = INPUT_KIND
	write_u32(buffer[2:6], value.sequence)
	buffer[6] = u8(value.axis[0])
	buffer[7] = u8(value.axis[1])
	return INPUT_SIZE, true
}

decode_input :: proc(buffer: []u8) -> (value: Input_Command, valid: bool) {
	if len(buffer) != INPUT_SIZE || buffer[0] != PROTOCOL_VERSION || buffer[1] != INPUT_KIND {return {}, false}
	value = Input_Command{sequence = read_u32(buffer[2:6]), axis = {i8(buffer[6]), i8(buffer[7])}}
	if !input_valid(value) {return {}, false}
	return value, true
}

encode_snapshot :: proc(value: Snapshot, buffer: []u8) -> (size: int, valid: bool) {
	value := value
	if !snapshot_valid(value) {return 0, false}
	size = SNAPSHOT_HEADER_SIZE + STATE_SIZE * value.count
	if len(buffer) < size {return 0, false}
	buffer[0] = PROTOCOL_VERSION
	buffer[1] = SNAPSHOT_KIND
	write_u32(buffer[2:6], value.tick)
	buffer[6] = u8(value.count)
	for state, index in value.states[:value.count] {
		offset := SNAPSHOT_HEADER_SIZE + STATE_SIZE * index
		write_u32(buffer[offset:offset+4], state.id)
		write_u32(buffer[offset+4:offset+8], state.owner_peer)
		write_u32(buffer[offset+8:offset+12], transmute(u32)state.position[0])
		write_u32(buffer[offset+12:offset+16], transmute(u32)state.position[1])
	}
	return size, true
}

decode_snapshot :: proc(buffer: []u8) -> (value: Snapshot, valid: bool) {
	if len(buffer) < SNAPSHOT_HEADER_SIZE || buffer[0] != PROTOCOL_VERSION || buffer[1] != SNAPSHOT_KIND {return {}, false}
	count := int(buffer[6])
	if count > MAX_ENTITIES || len(buffer) != SNAPSHOT_HEADER_SIZE + STATE_SIZE * count {return {}, false}
	value.tick = read_u32(buffer[2:6])
	value.count = count
	for index in 0 ..< count {
		offset := SNAPSHOT_HEADER_SIZE + STATE_SIZE * index
		value.states[index] = State{
			id = read_u32(buffer[offset:offset+4]),
			owner_peer = read_u32(buffer[offset+4:offset+8]),
			position = {transmute(f32)read_u32(buffer[offset+8:offset+12]), transmute(f32)read_u32(buffer[offset+12:offset+16])},
		}
	}
	if !snapshot_valid(value) {return {}, false}
	return value, true
}

@(private)
write_u32 :: proc(buffer: []u8, value: u32) {
	buffer[0] = u8(value >> 24)
	buffer[1] = u8((value >> 16) & 0xff)
	buffer[2] = u8((value >> 8) & 0xff)
	buffer[3] = u8(value & 0xff)
}

@(private)
read_u32 :: proc(buffer: []u8) -> u32 {
	return (u32(buffer[0]) << 24) | (u32(buffer[1]) << 16) | (u32(buffer[2]) << 8) | u32(buffer[3])
}
