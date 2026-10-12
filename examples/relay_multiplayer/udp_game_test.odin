package main

import "core:testing"
import "rune:ecs"
import "rune:replication"

udp_game_test_batch :: proc(first: u32, axes: [][2]i8) -> Game_Input_Batch {
	assert(len(axes) > 0 && len(axes) <= MAX_GAME_INPUT_COMMANDS)
	batch := Game_Input_Batch{count = len(axes)}
	for axis, index in axes {batch.commands[index] = {sequence = first + u32(index), axis = axis}}
	return batch
}

// Deliver only selected datagrams, in a chosen order. There are no timing or
// random-loss assumptions; the normal codec and host acceptance path still run.
udp_game_test_deliver :: proc(fixture: ^Game_Test_Fixture, batch: Game_Input_Batch) {
	bytes: [MAX_GAME_INPUT_SIZE]u8
	size, encoded := encode_game_input(batch, bytes[:])
	assert(encoded && game_receive_input(&fixture.host, &fixture.world, bytes[:size]))
}

udp_game_test_position :: proc(fixture: ^Game_Test_Fixture) -> [2]f32 {
	_, transform, _ := test_player(fixture, fixture.guest.peer_id)
	return {transform.position.x, transform.position.y}
}

udp_game_test_prediction :: proc(fixture: ^Game_Test_Fixture) -> Prediction_State {
	prediction: Prediction_State
	assert(prediction_reconcile(&prediction, udp_game_test_position(fixture), 0, false))
	return prediction
}

@(test)
udp_redundant_input_repairs_a_dropped_first_datagram :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	prediction := udp_game_test_prediction(&fixture)
	initial := prediction.position
	for axis, index in ([3][2]i8{{1,0}, {0,1}, {-1,0}}) {
		assert(prediction_record(&prediction, {sequence = u32(index+1), axis = axis}))
		// The first two packets are deliberately lost. The third still carries
		// those unacknowledged steps rather than only the newest direction.
		if index == 2 {udp_game_test_deliver(&fixture, game_pending_input(&prediction))}
	}
	testing.expect_value(t, fixture.host.inputs_received, u64(3))
	testing.expect(t, !fixture.host.has_guest_ack && udp_game_test_position(&fixture) == initial,
		"receiving a repair bundle cannot move or acknowledge unsimulated commands")
	for _ in 0..<3 {test_host_step(&fixture)}
	authoritative := udp_game_test_position(&fixture)
	testing.expect(t, fixture.host.guest_applied_sequence == 3 && fixture.host.guest_inputs.count == 0)
	testing.expect(t, authoritative == [2]f32{initial.x, initial.y + PLAYER_SPEED*MOVE_DT},
		"all three mixed-axis steps must execute once, including the dropped prefix")
	testing.expect(t, prediction_reconcile(&prediction, authoritative, 3, true))
	testing.expect(t, prediction.pending.count == 0 && prediction.position == authoritative)
}

@(test)
udp_future_bundle_waits_for_its_missing_prefix :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	queue := fixture.host.guest_inputs
	age, axis := fixture.host.guest_input_age, fixture.host.guest_axis
	version := ecs.change_version(&fixture.world)
	udp_game_test_deliver(&fixture, udp_game_test_batch(2, [][2]i8{{0,1}, {-1,0}}))
	testing.expect(t, fixture.host.guest_inputs == queue && !fixture.host.has_guest_sequence &&
		fixture.host.inputs_received == 0 && !fixture.host.has_guest_ack &&
		fixture.host.guest_input_age == age && fixture.host.guest_axis == axis &&
		ecs.change_version(&fixture.world) == version,
		"a future packet cannot skip missing sequence one or partially change host state")
	udp_game_test_deliver(&fixture, udp_game_test_batch(1, [][2]i8{{1,0}, {0,1}, {-1,0}}))
	testing.expect(t, fixture.host.inputs_received == 3 && fixture.host.guest_sequence == 3 && fixture.host.guest_inputs.count == 3)
	for _ in 0..<3 {test_host_step(&fixture)}
	testing.expect(t, fixture.host.guest_applied_sequence == 3 && fixture.host.guest_inputs.count == 0)
	testing.expect_value(t, fixture.host.rejected_messages, u64(0))
}

@(test)
udp_reordered_and_duplicate_bundles_do_not_repeat_movement :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	initial := udp_game_test_position(&fixture)
	newest := udp_game_test_batch(1, [][2]i8{{1,0}, {0,1}, {-1,0}})
	older := udp_game_test_batch(1, [][2]i8{{1,0}, {0,1}})
	udp_game_test_deliver(&fixture, newest)
	udp_game_test_deliver(&fixture, older)
	udp_game_test_deliver(&fixture, newest)
	testing.expect(t, fixture.host.inputs_received == 3 && fixture.host.guest_inputs.count == 3 && fixture.host.guest_sequence == 3)
	for _ in 0..<3 {test_host_step(&fixture)}
	after := udp_game_test_position(&fixture)
	testing.expect(t, after == [2]f32{initial.x, initial.y + PLAYER_SPEED*MOVE_DT})
	udp_game_test_deliver(&fixture, newest)
	test_host_step(&fixture)
	testing.expect(t, udp_game_test_position(&fixture) == after && fixture.host.guest_applied_sequence == 3 &&
		fixture.host.guest_inputs.count == 0 && fixture.host.inputs_received == 3,
		"a retransmission after a lost acknowledgement cannot simulate the same steps twice")
	testing.expect_value(t, fixture.host.rejected_messages, u64(0))
}

@(test)
udp_overlap_deduplicates_received_commands_before_their_ack :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	prediction := udp_game_test_prediction(&fixture)
	for axis, index in ([4][2]i8{{1,0}, {0,1}, {-1,0}, {0,0}}) {
		assert(prediction_record(&prediction, {sequence = u32(index+1), axis = axis}))
	}
	udp_game_test_deliver(&fixture, udp_game_test_batch(1, [][2]i8{{1,0}, {0,1}, {-1,0}}))
	test_host_step(&fixture)
	assert(fixture.host.guest_applied_sequence == 1 && fixture.host.guest_sequence == 3)
	assert(prediction_reconcile(&prediction, udp_game_test_position(&fixture), 1, true))
	udp_game_test_deliver(&fixture, game_pending_input(&prediction))
	testing.expect(t, fixture.host.inputs_received == 4 && fixture.host.guest_inputs.count == 3 && fixture.host.guest_sequence == 4,
		"the already received but unacknowledged commands two and three cannot be enqueued twice")
	for index in 0..<3 {
		command := fixture.host.guest_inputs.commands[(fixture.host.guest_inputs.head+index)%INPUT_HISTORY_CAPACITY]
		testing.expect_value(t, command.sequence, u32(index+2))
	}
	for _ in 0..<3 {test_host_step(&fixture)}
	before := prediction.position
	testing.expect(t, prediction_reconcile(&prediction, udp_game_test_position(&fixture), 4, true))
	testing.expect(t, prediction.pending.count == 0 && prediction.position == before && fixture.host.guest_inputs.count == 0)
}

@(test)
udp_malformed_last_command_rejects_the_entire_bundle :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	udp_game_test_deliver(&fixture, udp_game_test_batch(1, [][2]i8{{1,0}, {0,1}}))
	queue := fixture.host.guest_inputs
	sequence, axis, age := fixture.host.guest_sequence, fixture.host.guest_axis, fixture.host.guest_input_age
	version := ecs.change_version(&fixture.world)
	bytes: [MAX_GAME_INPUT_SIZE]u8
	size, valid := encode_game_input(udp_game_test_batch(3, [][2]i8{{-1,0}, {0,-1}, {1,0}}), bytes[:])
	assert(valid)
	bytes[GAME_INPUT_HEADER_SIZE + 2*replication.INPUT_SIZE + 6] = 127
	testing.expect(t, game_receive_input(&fixture.host, &fixture.world, bytes[:size]))
	testing.expect(t, fixture.host.guest_inputs == queue && fixture.host.guest_sequence == sequence &&
		fixture.host.guest_axis == axis && fixture.host.guest_input_age == age &&
		fixture.host.inputs_received == 2 && !fixture.host.has_guest_ack && ecs.change_version(&fixture.world) == version,
		"valid leading commands cannot survive rejection of a malformed trailing command")
	testing.expect_value(t, fixture.host.rejected_messages, u64(1))
}

@(test)
udp_ordered_input_and_acknowledgement_cross_sequence_wrap :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	initial := udp_game_test_position(&fixture)
	baseline := u32(0xfffffffd)
	fixture.host.guest_sequence, fixture.host.guest_applied_sequence = baseline, baseline
	fixture.host.has_guest_sequence, fixture.host.has_guest_ack = true, true
	prediction := Prediction_State{ready = true, position = initial, has_sent = true,
		latest_sequence = baseline, has_ack = true, last_ack = baseline}
	for sequence in ([]u32{0xfffffffe, 0xffffffff, 0, 1}) {
		assert(prediction_record(&prediction, {sequence = sequence, axis = {1,0}}))
	}
	udp_game_test_deliver(&fixture, game_pending_input(&prediction))
	testing.expect(t, fixture.host.guest_sequence == 1 && fixture.host.guest_inputs.count == 4)
	for _ in 0..<4 {test_host_step(&fixture)}
	authoritative := udp_game_test_position(&fixture)
	testing.expect(t, fixture.host.has_guest_ack && fixture.host.guest_applied_sequence == 1 &&
		authoritative == [2]f32{initial.x + 4*PLAYER_SPEED*MOVE_DT, initial.y})
	testing.expect(t, prediction_reconcile(&prediction, authoritative, 1, true))
	testing.expect(t, prediction.pending.count == 0 && prediction.last_ack == 1 && prediction.position == authoritative)
}

@(test)
udp_retransmission_recovers_unacknowledged_input_after_expiry :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	prediction := udp_game_test_prediction(&fixture)
	for sequence: u32 = 1; sequence <= 20; sequence += 1 {
		assert(prediction_record(&prediction, {sequence = sequence, axis = {1,0}}))
	}
	udp_game_test_deliver(&fixture, game_pending_input(&prediction))
	test_host_step(&fixture, 0.05)
	assert(fixture.host.guest_applied_sequence == 3 && fixture.host.guest_inputs.count == 17)
	after_three := udp_game_test_position(&fixture)
	test_host_step(&fixture, 0.20)
	testing.expect(t, udp_game_test_position(&fixture) == after_three && fixture.host.guest_inputs.count == 0 &&
		fixture.host.guest_sequence == 3 && fixture.host.guest_applied_sequence == 3,
		"expired receipt history must return to the last actually applied sequence")
	assert(prediction_reconcile(&prediction, after_three, 3, true))
	udp_game_test_deliver(&fixture, game_pending_input(&prediction))
	testing.expect(t, fixture.host.guest_inputs.count == 17 && fixture.host.guest_sequence == 20 && fixture.host.guest_applied_sequence == 3)
	for _ in 0..<INPUT_HISTORY_CAPACITY {
		if fixture.host.guest_applied_sequence == 20 {break}
		test_host_step(&fixture)
	}
	testing.expect(t, fixture.host.guest_applied_sequence == 20 && fixture.host.guest_inputs.count == 0)
	before := prediction.position
	testing.expect(t, prediction_reconcile(&prediction, udp_game_test_position(&fixture), 20, true))
	testing.expect(t, prediction.pending.count == 0 && prediction.position == before,
		"expiry recovery must execute the discarded prefix rather than skipping it with a cumulative acknowledgement")
}

@(test)
udp_twenty_lost_initial_packets_recover_while_new_inputs_continue :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	prediction := udp_game_test_prediction(&fixture)
	for sequence: u32 = 1; sequence <= 20; sequence += 1 {
		assert(prediction_record(&prediction, {sequence = sequence, axis = {1,0}}))
		// Discard this packet while the authoritative host keeps running.
		test_host_step(&fixture)
	}
	testing.expect(t, fixture.host.guest_input_credit >= 20 && fixture.host.inputs_received == 0,
		"unused monotonic host time must remain available to repair a 333 ms packet-loss burst")
	for sequence: u32 = 21; sequence <= 60; sequence += 1 {
		assert(prediction_record(&prediction, {sequence = sequence, axis = {1,0}}))
		udp_game_test_deliver(&fixture, game_pending_input(&prediction))
		test_host_step(&fixture)
		if fixture.host.has_guest_ack {
			assert(prediction_reconcile(&prediction, udp_game_test_position(&fixture),
				fixture.host.guest_applied_sequence, true))
		}
	}
	testing.expect(t, fixture.host.guest_inputs.count == 0 && fixture.host.guest_applied_sequence == 60 &&
		fixture.host.inputs_received == 60 && fixture.host.rejected_messages == 0 && prediction.pending.count == 0,
		"packet-loss debt must drain while new commands continue at the normal 60 Hz rate")
	testing.expect(t, udp_game_test_position(&fixture) == prediction.position,
		"catchup must preserve every predicted movement step without applying retransmissions twice")
}
