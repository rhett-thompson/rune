package main

import "rune:replication"

// Repeat the oldest unacknowledged steps so a newer UDP packet repairs loss
// without waiting for transport-level retransmission or skipping movement.
GAME_INPUT_VERSION :: u8(1)
GAME_INPUT_KIND :: u8(4)
GAME_INPUT_HEADER_SIZE :: 3
MAX_GAME_INPUT_COMMANDS :: 120
MAX_GAME_INPUT_SIZE :: GAME_INPUT_HEADER_SIZE + MAX_GAME_INPUT_COMMANDS*replication.INPUT_SIZE

Game_Input_Batch :: struct {
	count: int,
	commands: [MAX_GAME_INPUT_COMMANDS]replication.Input_Command,
}

encode_game_input :: proc(value: Game_Input_Batch, buffer: []u8) -> (int, bool) {
	if value.count < 1 || value.count > MAX_GAME_INPUT_COMMANDS {return 0, false}
	size := GAME_INPUT_HEADER_SIZE + value.count*replication.INPUT_SIZE
	if len(buffer) < size {return 0, false}
	for index in 0..<value.count {
		command := value.commands[index]
		if !replication.input_valid(command) || (index > 0 && command.sequence != value.commands[index-1].sequence + 1) {return 0, false}
	}
	buffer[0], buffer[1], buffer[2] = GAME_INPUT_VERSION, GAME_INPUT_KIND, u8(value.count)
	for index in 0..<value.count {
		offset := GAME_INPUT_HEADER_SIZE + index*replication.INPUT_SIZE
		_, valid := replication.encode_input(value.commands[index], buffer[offset:offset+replication.INPUT_SIZE])
		assert(valid)
	}
	return size, true
}

decode_game_input :: proc(buffer: []u8) -> (Game_Input_Batch, bool) {
	if len(buffer) < GAME_INPUT_HEADER_SIZE || buffer[0] != GAME_INPUT_VERSION || buffer[1] != GAME_INPUT_KIND {return {}, false}
	count := int(buffer[2])
	if count < 1 || count > MAX_GAME_INPUT_COMMANDS || len(buffer) != GAME_INPUT_HEADER_SIZE + count*replication.INPUT_SIZE {return {}, false}
	batch := Game_Input_Batch{count = count}
	for index in 0..<count {
		offset := GAME_INPUT_HEADER_SIZE + index*replication.INPUT_SIZE
		command, valid := replication.decode_input(buffer[offset:offset+replication.INPUT_SIZE])
		if !valid || (index > 0 && command.sequence != batch.commands[index-1].sequence + 1) {return {}, false}
		batch.commands[index] = command
	}
	return batch, true
}

game_pending_input :: proc(prediction: ^Prediction_State) -> Game_Input_Batch {
	batch := Game_Input_Batch{count = min(prediction.pending.count, MAX_GAME_INPUT_COMMANDS)}
	for index in 0..<batch.count {
		batch.commands[index] = prediction.pending.commands[(prediction.pending.head+index)%INPUT_HISTORY_CAPACITY]
	}
	return batch
}

// This example wraps the shared v1 snapshot with the last input command the
// host actually simulated. The shared input and snapshot codecs stay unchanged.
GAME_SNAPSHOT_VERSION :: u8(1)
GAME_SNAPSHOT_KIND :: u8(3)
GAME_SNAPSHOT_HEADER_SIZE :: 7
MAX_GAME_SNAPSHOT_SIZE :: GAME_SNAPSHOT_HEADER_SIZE + replication.MAX_SNAPSHOT_SIZE

Game_Snapshot :: struct {
	snapshot: replication.Snapshot,
	ack: u32,
	has_ack: bool,
}

encode_game_snapshot :: proc(value: Game_Snapshot, buffer: []u8) -> (int, bool) {
	if (!value.has_ack && value.ack != 0) || len(buffer) < GAME_SNAPSHOT_HEADER_SIZE {return 0, false}
	size, valid := replication.encode_snapshot(value.snapshot, buffer[GAME_SNAPSHOT_HEADER_SIZE:])
	if !valid {return 0, false}
	buffer[0] = GAME_SNAPSHOT_VERSION
	buffer[1] = GAME_SNAPSHOT_KIND
	buffer[2] = 1 if value.has_ack else 0
	buffer[3] = u8(value.ack >> 24)
	buffer[4] = u8((value.ack >> 16) & 0xff)
	buffer[5] = u8((value.ack >> 8) & 0xff)
	buffer[6] = u8(value.ack & 0xff)
	return GAME_SNAPSHOT_HEADER_SIZE + size, true
}

decode_game_snapshot :: proc(buffer: []u8) -> (Game_Snapshot, bool) {
	if len(buffer) < GAME_SNAPSHOT_HEADER_SIZE + replication.SNAPSHOT_HEADER_SIZE ||
	   len(buffer) > MAX_GAME_SNAPSHOT_SIZE || buffer[0] != GAME_SNAPSHOT_VERSION ||
	   buffer[1] != GAME_SNAPSHOT_KIND || buffer[2] > 1 {return {}, false}
	ack := (u32(buffer[3]) << 24) | (u32(buffer[4]) << 16) | (u32(buffer[5]) << 8) | u32(buffer[6])
	has_ack := buffer[2] == 1
	if !has_ack && ack != 0 {return {}, false}
	snapshot, valid := replication.decode_snapshot(buffer[GAME_SNAPSHOT_HEADER_SIZE:])
	if !valid {return {}, false}
	return Game_Snapshot{snapshot = snapshot, ack = ack, has_ack = has_ack}, true
}
