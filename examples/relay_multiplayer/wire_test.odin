package main

import "core:math"
import "core:slice"
import "core:testing"
import "rune:replication"

game_wire_fixture :: proc() -> [30]u8 {
	return {
		1, 3, 1, 0x01, 0x23, 0x45, 0x67,
		1, 2, 0x89, 0xab, 0xcd, 0xef, 1,
		0x01, 0x23, 0x45, 0x67, 0x76, 0x54, 0x32, 0x10,
		0x3f, 0xc0, 0, 0, 0xc0, 0x10, 0, 0,
	}
}

@(test)
game_input_batches_roundtrip_contiguous_commands_and_wrap :: proc(t: ^testing.T) {
	value := Game_Input_Batch{count=4}
	value.commands[0], value.commands[1] = {0xfffffffe, {1,0}}, {0xffffffff, {0,1}}
	value.commands[2], value.commands[3] = {0, {-1,0}}, {1, {0,-1}}
	buffer: [MAX_GAME_INPUT_SIZE]u8
	size, encoded := encode_game_input(value, buffer[:])
	decoded, valid := decode_game_input(buffer[:size])
	testing.expect(t, encoded && valid && decoded == value && size == GAME_INPUT_HEADER_SIZE + 4*replication.INPUT_SIZE)
	testing.expect(t, buffer[0] == 1 && buffer[1] == 4 && buffer[2] == 4)
	for index in 0..<value.count {
		offset := GAME_INPUT_HEADER_SIZE + index*replication.INPUT_SIZE
		command, shared_valid := replication.decode_input(buffer[offset:offset+replication.INPUT_SIZE])
		testing.expect(t, shared_valid && command == value.commands[index], "each command preserves the portable shared input format")
	}
}

@(test)
game_input_batches_reject_malformed_data_atomically :: proc(t: ^testing.T) {
	value := Game_Input_Batch{count=2}
	value.commands[0], value.commands[1] = {1, {1,0}}, {2, {0,1}}
	buffer: [MAX_GAME_INPUT_SIZE+1]u8
	size, encoded := encode_game_input(value, buffer[:])
	assert(encoded)
	for truncated in 0..<size {
		_, valid := decode_game_input(buffer[:truncated])
		testing.expect(t, !valid)
	}
	_, valid := decode_game_input(buffer[:size+1])
	testing.expect(t, !valid, "a batch must consume exactly one complete payload")
	for index in ([4]int{0, 1, 2, size-1}) {
		bad := buffer
		bad[index] = 127 if index == size-1 else 0xff
		decoded, accepted := decode_game_input(bad[:size])
		testing.expect(t, !accepted && decoded == Game_Input_Batch{}, "even a malformed final command cannot return a valid prefix")
	}
	for count in ([3]int{0, -1, MAX_GAME_INPUT_COMMANDS+1}) {
		bad := value
		bad.count = count
		_, valid = encode_game_input(bad, buffer[:])
		testing.expect(t, !valid)
	}
	value.commands[1].sequence = 3
	_, valid = encode_game_input(value, buffer[:])
	testing.expect(t, !valid, "internal sequence gaps must be rejected before sending")
	buffer[GAME_INPUT_HEADER_SIZE+replication.INPUT_SIZE+5] = 3
	_, valid = decode_game_input(buffer[:size])
	testing.expect(t, !valid, "internal sequence gaps cannot enter the host queue")
}

@(test)
game_input_batch_selects_oldest_unacknowledged_history_under_payload_limit :: proc(t: ^testing.T) {
	state := Prediction_State{ready=true, position={640,400}}
	for sequence: u32 = 1; sequence <= INPUT_HISTORY_CAPACITY; sequence += 1 {
		assert(prediction_record(&state, {sequence=sequence}))
	}
	batch := game_pending_input(&state)
	testing.expect(t, batch.count == MAX_GAME_INPUT_COMMANDS && batch.commands[0].sequence == 1 && batch.commands[batch.count-1].sequence == MAX_GAME_INPUT_COMMANDS,
		"repeating the earliest unacknowledged commands repairs a missing prefix instead of indefinitely skipping it")
	buffer: [MAX_GAME_INPUT_SIZE]u8
	size, encoded := encode_game_input(batch, buffer[:])
	testing.expect(t, encoded && size == MAX_GAME_INPUT_SIZE && size <= 1024)
	assert(prediction_reconcile(&state, {640,400}, 100, true))
	batch = game_pending_input(&state)
	testing.expect(t, batch.count == MAX_GAME_INPUT_COMMANDS && batch.commands[0].sequence == 101 && batch.commands[batch.count-1].sequence == 220)
}

@(test)
game_snapshot_wire_fixture_preserves_shared_payload :: proc(t: ^testing.T) {
	fixture := game_wire_fixture()
	value, valid := decode_game_snapshot(fixture[:])
	testing.expect(t, valid && value.has_ack && value.ack == 0x01234567)
	testing.expect(t, value.snapshot.tick == 0x89abcdef && value.snapshot.count == 1)
	testing.expect_value(t, value.snapshot.states[0], replication.State{0x01234567, 0x76543210, {1.5, -2.25}})
	buffer: [MAX_GAME_SNAPSHOT_SIZE]u8
	size, encoded := encode_game_snapshot(value, buffer[:])
	testing.expect(t, encoded && size == len(fixture) && slice.equal(buffer[:size], fixture[:]))
	shared, shared_valid := replication.decode_snapshot(fixture[GAME_SNAPSHOT_HEADER_SIZE:])
	testing.expect(t, shared_valid && shared == value.snapshot)
	_, valid = replication.decode_snapshot(fixture[:])
	testing.expect(t, !valid, "the example envelope has its own kind")
	_, valid = decode_game_snapshot(fixture[GAME_SNAPSHOT_HEADER_SIZE:])
	testing.expect(t, !valid, "an unwrapped shared snapshot cannot supply an input acknowledgement")
	input_fixture := [replication.INPUT_SIZE]u8{1, 1, 0x01, 0x23, 0x45, 0x67, 0xff, 1}
	command, input_valid := replication.decode_input(input_fixture[:])
	testing.expect(t, input_valid && command == replication.Input_Command{0x01234567, {-1, 1}},
		"input commands retain the shared eight-byte wire format")
}

@(test)
game_snapshot_ack_presence_is_canonical_and_allows_sequence_zero :: proc(t: ^testing.T) {
	buffer: [MAX_GAME_SNAPSHOT_SIZE]u8
	for has_ack in ([2]bool{false, true}) {
		value := Game_Snapshot{snapshot = {tick = 42}, ack = 0, has_ack = has_ack}
		size, encoded := encode_game_snapshot(value, buffer[:])
		decoded, valid := decode_game_snapshot(buffer[:size])
		testing.expect(t, encoded && valid && decoded == value && size == GAME_SNAPSHOT_HEADER_SIZE + replication.SNAPSHOT_HEADER_SIZE)
		testing.expect_value(t, buffer[2], u8(1) if has_ack else u8(0))
	}
	_, valid := encode_game_snapshot({ack = 1, has_ack = false}, buffer[:])
	testing.expect(t, !valid, "absent acknowledgements must encode zero")
	fixture := game_wire_fixture()
	fixture[2] = 0
	_, valid = decode_game_snapshot(fixture[:])
	testing.expect(t, !valid, "an absent acknowledgement cannot carry a nonzero serial number")
}

@(test)
game_snapshot_rejects_malformed_headers_and_lengths :: proc(t: ^testing.T) {
	fixture := game_wire_fixture()
	for size in 0..<len(fixture) {
		_, valid := decode_game_snapshot(fixture[:size])
		testing.expect(t, !valid, "truncated headers and payloads are rejected")
	}
	for index in ([3]int{0, 1, 2}) {
		for replacement in ([3]u8{2, 0xff, 0}) {
			if index == 1 && replacement == GAME_SNAPSHOT_KIND {continue}
			bad := fixture
			bad[index] = replacement
			_, valid := decode_game_snapshot(bad[:])
			testing.expect(t, !valid, "unknown version, kind, flags, and noncanonical absent acknowledgements are rejected")
		}
	}
	buffer: [MAX_GAME_SNAPSHOT_SIZE+1]u8
	copy(buffer[:], fixture[:])
	_, valid := decode_game_snapshot(buffer[:len(fixture)+1])
	testing.expect(t, !valid, "trailing payload bytes are rejected")
	_, valid = decode_game_snapshot(buffer[:])
	testing.expect(t, !valid, "oversized payloads are rejected")
	value, decoded := decode_game_snapshot(fixture[:])
	assert(decoded)
	for size in 0..<len(fixture) {
		_, valid = encode_game_snapshot(value, buffer[:size])
		testing.expect(t, !valid, "the encoder requires space for the complete envelope")
	}
}

@(test)
game_snapshot_rejects_invalid_shared_snapshot_content :: proc(t: ^testing.T) {
	fixture := game_wire_fixture()
	for index in ([3]int{7, 8, 13}) {
		bad := fixture
		bad[index] = 0xff
		_, valid := decode_game_snapshot(bad[:])
		testing.expect(t, !valid, "shared snapshot version, kind, and entity count remain validated")
	}
	for offset in ([2]int{14, 18}) {
		bad := fixture
		for index in offset..<offset+4 {bad[index] = 0}
		_, valid := decode_game_snapshot(bad[:])
		testing.expect(t, !valid, "zero entity IDs and owners are rejected")
	}
	bad := fixture
	bad[22], bad[23], bad[24], bad[25] = 0x7f, 0x80, 0, 0
	_, valid := decode_game_snapshot(bad[:])
	testing.expect(t, !valid, "nonfinite coordinates are rejected by the shared codec")
	value, decoded := decode_game_snapshot(fixture[:])
	assert(decoded)
	buffer: [MAX_GAME_SNAPSHOT_SIZE]u8
	duplicate := value
	duplicate.snapshot.count = 2
	duplicate.snapshot.states[1] = duplicate.snapshot.states[0]
	_, valid = encode_game_snapshot(duplicate, buffer[:])
	testing.expect(t, !valid, "duplicate IDs cannot be encoded")
	copy(buffer[:], fixture[:])
	copy(buffer[len(fixture):len(fixture)+replication.STATE_SIZE], fixture[14:])
	buffer[13] = 2
	_, valid = decode_game_snapshot(buffer[:len(fixture)+replication.STATE_SIZE])
	testing.expect(t, !valid, "duplicate wire IDs cannot be decoded")
	for count in ([2]int{-1, replication.MAX_ENTITIES+1}) {
		invalid := value
		invalid.snapshot.count = count
		_, valid = encode_game_snapshot(invalid, buffer[:])
		testing.expect(t, !valid)
	}
	value.snapshot.states[0].position[0] = math.nan_f32()
	_, valid = encode_game_snapshot(value, buffer[:])
	testing.expect(t, !valid, "nonfinite snapshot values cannot be encoded")
}

@(test)
game_snapshot_supports_the_shared_maximum_and_wrapped_ack :: proc(t: ^testing.T) {
	value := Game_Snapshot{snapshot = {tick = 3, count = replication.MAX_ENTITIES}, has_ack = true, ack = 0xffffffff}
	for index in 0..<replication.MAX_ENTITIES {
		value.snapshot.states[index] = {u32(index+1), 1, {f32(index), -f32(index)}}
	}
	buffer: [MAX_GAME_SNAPSHOT_SIZE]u8
	size, encoded := encode_game_snapshot(value, buffer[:])
	decoded, valid := decode_game_snapshot(buffer[:size])
	testing.expect(t, encoded && valid && size == MAX_GAME_SNAPSHOT_SIZE && decoded == value)
}
