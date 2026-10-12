package main

import "core:math"
import "core:testing"

prediction_test_position :: proc(t: ^testing.T, actual, expected: [2]f32, tolerance: f32 = 0.001) {
	testing.expect(t, abs(actual[0] - expected[0]) <= tolerance && abs(actual[1] - expected[1]) <= tolerance)
}

@(test)
input_history_is_bounded_fifo_and_reuses_wrapped_storage :: proc(t: ^testing.T) {
	queue: Input_Queue
	for sequence in 0..<INPUT_HISTORY_CAPACITY {
		testing.expect(t, input_queue_push(&queue, {sequence = u32(sequence), axis = {1, 0}}))
	}
	full := queue
	testing.expect(t, !input_queue_push(&queue, {sequence = 999}))
	testing.expect_value(t, queue, full)
	for sequence in 0..<INPUT_HISTORY_CAPACITY/2 {
		command, available := input_queue_pop(&queue)
		testing.expect(t, available && command.sequence == u32(sequence) && command.axis == [2]i8{1, 0})
	}
	for sequence in INPUT_HISTORY_CAPACITY..<INPUT_HISTORY_CAPACITY+INPUT_HISTORY_CAPACITY/2 {
		testing.expect(t, input_queue_push(&queue, {sequence = u32(sequence), axis = {-1, 0}}))
	}
	for sequence in INPUT_HISTORY_CAPACITY/2..<INPUT_HISTORY_CAPACITY+INPUT_HISTORY_CAPACITY/2 {
		command, available := input_queue_pop(&queue)
		testing.expect(t, available && command.sequence == u32(sequence))
		expected := [2]i8{1, 0} if sequence < INPUT_HISTORY_CAPACITY else [2]i8{-1, 0}
		testing.expect_value(t, command.axis, expected)
	}
	testing.expect_value(t, queue.count, 0)
	empty := queue
	_, available := input_queue_pop(&queue)
	testing.expect(t, !available)
	testing.expect_value(t, queue, empty)
	queue = {}
	testing.expect(t, input_queue_push(&queue, {sequence = 1}))
	first_command, first_available := input_queue_pop(&queue)
	testing.expect(t, first_available && first_command.sequence == 1)
	for malformed in ([]Input_Queue{{head = -1}, {head = INPUT_HISTORY_CAPACITY}, {count = INPUT_HISTORY_CAPACITY + 1}}) {
		bad := malformed
		testing.expect(t, !input_queue_push(&bad, {}))
		_, available = input_queue_pop(&bad)
		testing.expect(t, !available)
		testing.expect_value(t, bad, malformed)
	}
}

@(test)
local_prediction_moves_immediately_without_a_server_response :: proc(t: ^testing.T) {
	state: Prediction_State
	original := state
	testing.expect(t, !prediction_record(&state, {sequence = 1, axis = {1, 0}}))
	testing.expect_value(t, state, original)
	testing.expect(t, prediction_reconcile(&state, {200, 300}, 0, false))
	testing.expect(t, state.ready && !state.has_sent && !state.has_ack)
	testing.expect(t, prediction_record(&state, {sequence = 1, axis = {1, 0}}))
	prediction_test_position(t, state.position, {203, 300})
	testing.expect(t, state.pending.count == 1 && state.latest_sequence == 1 && state.has_sent)
	testing.expect(t, prediction_record(&state, {sequence = 2, axis = {0, -1}}))
	prediction_test_position(t, state.position, {203, 297})
}

@(test)
one_second_of_guest_prediction_matches_authoritative_movement_speed :: proc(t: ^testing.T) {
	state: Prediction_State
	start := [2]f32{200, 300}
	testing.expect(t, prediction_reconcile(&state, start, 0, false))
	authoritative := start
	for sequence: u32 = 1; sequence <= 60; sequence += 1 {
		testing.expect(t, prediction_record(&state, {sequence = sequence, axis = {1, 0}}))
		authoritative = move_position(authoritative, {1, 0}, MOVE_DT)
	}
	prediction_test_position(t, state.position, {start[0] + PLAYER_SPEED, start[1]})
	prediction_test_position(t, state.position, authoritative)
	testing.expect_value(t, state.pending.count, 60)
}

@(test)
reconciliation_replays_only_unacknowledged_steps_without_double_movement :: proc(t: ^testing.T) {
	state: Prediction_State
	testing.expect(t, prediction_reconcile(&state, {200, 300}, 0, false))
	testing.expect(t, prediction_record(&state, {sequence = 1, axis = {1, 0}}))
	testing.expect(t, prediction_record(&state, {sequence = 2, axis = {1, 0}}))
	testing.expect(t, prediction_record(&state, {sequence = 3, axis = {0, -1}}))
	prediction_test_position(t, state.position, {206, 297})
	// The host corrected the first two steps by one unit. The third step is
	// still pending, and must be replayed from that corrected authority once.
	for _ in 0..<3 {
		testing.expect(t, prediction_reconcile(&state, {205, 300}, 2, true))
		prediction_test_position(t, state.position, {205, 297})
		testing.expect(t, state.pending.count == 1 && state.pending.commands[state.pending.head].sequence == 3)
	}
	testing.expect(t, prediction_reconcile(&state, {205, 297}, 3, true))
	testing.expect(t, state.pending.count == 0 && state.latest_sequence == 3 && state.has_sent && state.last_ack == 3 && state.has_ack)
	testing.expect(t, !prediction_record(&state, {sequence = 3, axis = {1, 0}}))
	testing.expect(t, prediction_record(&state, {sequence = 4, axis = {1, 0}}))
	prediction_test_position(t, state.position, {208, 297})
}

@(test)
unacknowledged_snapshots_rebuild_from_authority_instead_of_accumulating :: proc(t: ^testing.T) {
	state: Prediction_State
	testing.expect(t, prediction_reconcile(&state, {200, 300}, 0, false))
	testing.expect(t, prediction_record(&state, {sequence = 1, axis = {1, 0}}))
	testing.expect(t, prediction_record(&state, {sequence = 2, axis = {1, 0}}))
	for _ in 0..<3 {
		testing.expect(t, prediction_reconcile(&state, {199, 300}, 0, false))
		prediction_test_position(t, state.position, {205, 300})
		testing.expect(t, state.pending.count == 2 && !state.has_ack)
	}
}

@(test)
prediction_rejects_invalid_commands_acknowledgments_and_positions_atomically :: proc(t: ^testing.T) {
	state: Prediction_State
	testing.expect(t, prediction_reconcile(&state, {200, 300}, 0, false))
	initial := state
	testing.expect(t, !prediction_reconcile(&state, {200, 300}, 0, true), "an acknowledgment cannot precede all sent inputs")
	testing.expect(t, !prediction_reconcile(&state, {200, 300}, 1, false))
	testing.expect_value(t, state, initial)
	for sequence: u32 = 10; sequence <= 12; sequence += 1 {testing.expect(t, prediction_record(&state, {sequence = sequence, axis = {1, 0}}))}
	testing.expect(t, prediction_reconcile(&state, {206, 300}, 11, true))
	original := state
	for ack in ([]u32{10, 13, 0x8000000c}) {
		testing.expect(t, !prediction_reconcile(&state, {206, 300}, ack, true))
		testing.expect_value(t, state, original)
	}
	testing.expect(t, !prediction_reconcile(&state, {206, 300}, 0, false), "acknowledged history cannot return to an unacknowledged state")
	testing.expect_value(t, state, original)
	for position in ([][2]f32{
		{ARENA_MIN[0] - 1, 300}, {200, ARENA_MAX[1] + 1},
		{math.nan_f32(), 300}, {200, math.inf_f32(1)},
	}) {
		testing.expect(t, !prediction_reconcile(&state, position, 12, true))
		testing.expect_value(t, state, original)
	}
	for command in ([]struct {sequence: u32, axis: [2]i8}{
		{12, {-1, 0}}, {11, {-1, 0}}, {0x8000000c, {1, 0}}, {13, {2, 0}}, {13, {0, -2}},
	}) {
		testing.expect(t, !prediction_record(&state, {sequence = command.sequence, axis = command.axis}))
		testing.expect_value(t, state, original)
	}
}

@(test)
prediction_acknowledgments_and_new_inputs_cross_sequence_wrap_safely :: proc(t: ^testing.T) {
	state: Prediction_State
	testing.expect(t, prediction_reconcile(&state, {200, 300}, 0, false))
	for sequence in ([]u32{0xfffffffe, 0xffffffff, 0, 1}) {testing.expect(t, prediction_record(&state, {sequence = sequence, axis = {1, 0}}))}
	testing.expect(t, prediction_reconcile(&state, {206, 300}, 0xffffffff, true))
	testing.expect(t, state.pending.count == 2 && state.last_ack == 0xffffffff)
	prediction_test_position(t, state.position, {212, 300})
	testing.expect(t, prediction_reconcile(&state, {209, 300}, 0, true))
	testing.expect(t, state.pending.count == 1 && state.last_ack == 0)
	prediction_test_position(t, state.position, {212, 300})
	original := state
	testing.expect(t, !prediction_reconcile(&state, {209, 300}, 0xffffffff, true))
	testing.expect(t, !prediction_reconcile(&state, {209, 300}, 2, true))
	testing.expect_value(t, state, original)
	testing.expect(t, prediction_reconcile(&state, {212, 300}, 1, true))
	testing.expect(t, state.pending.count == 0 && state.latest_sequence == 1 && state.has_sent)
	testing.expect(t, prediction_record(&state, {sequence = 2, axis = {1, 0}}))
	prediction_test_position(t, state.position, {215, 300})
}

@(test)
prediction_overflow_does_not_move_or_forget_unacknowledged_inputs :: proc(t: ^testing.T) {
	state: Prediction_State
	testing.expect(t, prediction_reconcile(&state, {200, 300}, 0, false))
	for sequence: u32 = 1; sequence <= INPUT_HISTORY_CAPACITY; sequence += 1 {testing.expect(t, prediction_record(&state, {sequence = sequence}))}
	original := state
	testing.expect(t, !prediction_record(&state, {sequence = INPUT_HISTORY_CAPACITY + 1, axis = {1, 0}}))
	testing.expect_value(t, state, original)
	testing.expect(t, prediction_reconcile(&state, {200, 300}, INPUT_HISTORY_CAPACITY, true))
	testing.expect(t, state.pending.count == 0)
	testing.expect(t, prediction_record(&state, {sequence = INPUT_HISTORY_CAPACITY + 1, axis = {1, 0}}))
	prediction_test_position(t, state.position, {203, 300})
}

@(test)
shared_movement_normalizes_diagonals_and_clamps_arena_edges :: proc(t: ^testing.T) {
	start := [2]f32{200, 300}
	cardinal := move_position(start, {1, 0}, MOVE_DT) - start
	diagonal := move_position(start, {1, 1}, MOVE_DT) - start
	testing.expect(t, abs(math.sqrt(diagonal[0]*diagonal[0] + diagonal[1]*diagonal[1]) - cardinal[0]) < 0.001)
	testing.expect(t, diagonal[0] > 0 && abs(diagonal[0] - diagonal[1]) < 0.001)
	prediction_test_position(t, move_position(ARENA_MAX, {1, 1}, MOVE_DT), ARENA_MAX)
	prediction_test_position(t, move_position(ARENA_MIN, {-1, -1}, MOVE_DT), ARENA_MIN)
	prediction_test_position(t, move_position(start, {2, 0}, MOVE_DT), start)
	for dt in ([]f32{0, -1, math.nan_f32(), math.inf_f32(1)}) {prediction_test_position(t, move_position(start, {1, 0}, dt), start)}
}

@(test)
remote_presentation_moves_each_frame_and_retargets_without_a_jump :: proc(t: ^testing.T) {
	remote: Remote_Smoothing
	remote_target(&remote, {200, 300})
	prediction_test_position(t, remote.position, {200, 300})
	remote_target(&remote, {209, 300})
	for index in 1..=3 {
		remote_advance(&remote, MOVE_DT)
		prediction_test_position(t, remote.position, {200 + 3*f32(index), 300})
	}
	remote_target(&remote, {239, 300})
	remote_advance(&remote, SMOOTH_INTERVAL/2)
	prediction_test_position(t, remote.position, {224, 300})
	remote_target(&remote, {254, 300})
	prediction_test_position(t, remote.position, {224, 300})
	remote_advance(&remote, SMOOTH_INTERVAL/2)
	prediction_test_position(t, remote.position, {239, 300})
	remote_advance(&remote, 10)
	prediction_test_position(t, remote.position, {254, 300})
	remote_advance(&remote, 10)
	prediction_test_position(t, remote.position, {254, 300})
}

@(test)
remote_presentation_snaps_teleports_and_ignores_invalid_updates :: proc(t: ^testing.T) {
	remote: Remote_Smoothing
	remote_target(&remote, {200, 300})
	remote_target(&remote, {264, 300})
	prediction_test_position(t, remote.position, {200, 300}, 0)
	remote_advance(&remote, SMOOTH_INTERVAL)
	remote_target(&remote, {329, 300})
	prediction_test_position(t, remote.position, {329, 300}, 0)
	before := remote
	for dt in ([]f32{0, -1, math.nan_f32(), math.inf_f32(1)}) {
		remote_advance(&remote, dt)
		testing.expect_value(t, remote, before)
	}
	remote_target(&remote, {math.nan_f32(), 300})
	remote_target(&remote, {ARENA_MAX[0] + 1, 300})
	testing.expect_value(t, remote, before)
}

@(test)
correction_presentation_decays_without_delaying_new_local_input :: proc(t: ^testing.T) {
	correction: Correction_Smoothing
	base := [2]f32{290, 300}
	correction_set(&correction, {300, 300}, base)
	prediction_test_position(t, correction_position(correction, base), {300, 300})
	// A fresh predicted step is visible in full even before the old visual
	// correction has decayed; only the reconciliation difference is smoothed.
	base = move_position(base, {1, 0}, MOVE_DT)
	prediction_test_position(t, correction_position(correction, base), {303, 300})
	correction_advance(&correction, SMOOTH_INTERVAL)
	prediction_test_position(t, correction.offset, {10*f32(math.exp(-0.9)), 0})
	testing.expect(t, correction_position(correction, base)[0] > base[0])
	correction_advance(&correction, 1)
	prediction_test_position(t, correction_position(correction, base), base)
}

@(test)
correction_decay_is_frame_rate_independent_and_large_corrections_snap :: proc(t: ^testing.T) {
	one := Correction_Smoothing{offset = {10, -5}}
	two := one
	correction_advance(&one, 0.05)
	correction_advance(&two, 0.025)
	correction_advance(&two, 0.025)
	prediction_test_position(t, one.offset, two.offset)
	correction_set(&one, {300, 300}, {236, 300})
	prediction_test_position(t, one.offset, {64, 0}, 0)
	correction_set(&one, {300, 300}, {235, 300})
	prediction_test_position(t, one.offset, {}, 0)
	correction_set(&one, ARENA_MAX, {ARENA_MAX[0] - 32, ARENA_MAX[1] - 32})
	prediction_test_position(t, correction_position(one, ARENA_MAX), ARENA_MAX, 0)
	before := one
	for dt in ([]f32{0, -1, math.nan_f32(), math.inf_f32(1)}) {
		correction_advance(&one, dt)
		testing.expect_value(t, one, before)
	}
	correction_set(&one, {math.inf_f32(1), 300}, {200, 300})
	testing.expect_value(t, one, before)
}
