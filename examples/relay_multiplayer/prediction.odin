package main

import "core:math"
import "rune:replication"

INPUT_HISTORY_CAPACITY :: 256
MOVE_DT :: f32(1.0 / 60.0)
SMOOTH_INTERVAL :: f32(0.05)
PRESENTATION_SNAP_DISTANCE :: f32(64)
CORRECTION_DECAY :: f32(18)

// One command represents one fixed movement step. Both the host's receive
// queue and the guest's unacknowledged history have a fixed storage limit.
Input_Queue :: struct {
	commands: [INPUT_HISTORY_CAPACITY]replication.Input_Command,
	head, count: int,
}

@(private="file")
input_queue_valid :: proc(queue: ^Input_Queue) -> bool {
	return queue != nil && queue.head >= 0 && queue.head < INPUT_HISTORY_CAPACITY &&
		queue.count >= 0 && queue.count <= INPUT_HISTORY_CAPACITY
}

input_queue_push :: proc(queue: ^Input_Queue, command: replication.Input_Command) -> bool {
	if !input_queue_valid(queue) || queue.count == INPUT_HISTORY_CAPACITY {return false}
	index := (queue.head + queue.count) % INPUT_HISTORY_CAPACITY
	queue.commands[index] = command
	queue.count += 1
	return true
}

input_queue_pop :: proc(queue: ^Input_Queue) -> (replication.Input_Command, bool) {
	if !input_queue_valid(queue) || queue.count == 0 {return {}, false}
	command := queue.commands[queue.head]
	queue.commands[queue.head] = {}
	queue.head = (queue.head + 1) % INPUT_HISTORY_CAPACITY
	queue.count -= 1
	if queue.count == 0 {queue.head = 0}
	return command, true
}

@(private="file")
prediction_position_valid :: proc(position: [2]f32) -> bool {
	for value in position {if math.is_nan(value) || math.is_inf(value) {return false}}
	return position[0] >= ARENA_MIN[0] && position[0] <= ARENA_MAX[0] &&
		position[1] >= ARENA_MIN[1] && position[1] <= ARENA_MAX[1]
}

@(private="file")
presentation_dt_valid :: proc(dt: f32) -> bool {
	return dt > 0 && !math.is_nan(dt) && !math.is_inf(dt)
}

@(private="file")
clamp_position :: proc(position: [2]f32) -> [2]f32 {
	return {clamp(position[0], ARENA_MIN[0], ARENA_MAX[0]), clamp(position[1], ARENA_MIN[1], ARENA_MAX[1])}
}

// The authoritative host and the predicted guest use identical movement math.
move_position :: proc(position: [2]f32, axis: [2]i8, dt: f32) -> [2]f32 {
	if !presentation_dt_valid(dt) || !replication.input_valid({axis = axis}) {return clamp_position(position)}
	direction := [2]f32{f32(axis[0]), f32(axis[1])}
	if direction[0] != 0 && direction[1] != 0 {direction *= f32(1 / math.sqrt(2.0))}
	return clamp_position(position + direction * PLAYER_SPEED * dt)
}

Prediction_State :: struct {
	pending: Input_Queue,
	ready: bool,
	position: [2]f32,
	latest_sequence: u32,
	has_sent: bool,
	last_ack: u32,
	has_ack: bool,
}

prediction_record :: proc(state: ^Prediction_State, command: replication.Input_Command) -> bool {
	if state == nil || !state.ready || !prediction_position_valid(state.position) || !replication.input_valid(command) {return false}
	if state.has_sent && !replication.sequence_newer(command.sequence, state.latest_sequence) {return false}
	if !input_queue_push(&state.pending, command) {return false}
	state.position = move_position(state.position, command.axis, MOVE_DT)
	state.latest_sequence = command.sequence
	state.has_sent = true
	return true
}

// Rebuild from the latest authoritative position instead of applying a
// correction to already-predicted movement. Each remaining command is replayed
// exactly once, including when consecutive snapshots acknowledge the same step.
prediction_reconcile :: proc(state: ^Prediction_State, authoritative: [2]f32, ack: u32, has_ack: bool) -> bool {
	if state == nil || !prediction_position_valid(authoritative) || !input_queue_valid(&state.pending) {return false}
	if has_ack {
		if !state.has_sent || (ack != state.latest_sequence && !replication.sequence_newer(state.latest_sequence, ack)) {return false}
		if state.has_ack && ack != state.last_ack && !replication.sequence_newer(ack, state.last_ack) {return false}
	} else if ack != 0 || state.has_ack {
		return false
	}
	next := state^
	if has_ack {
		for next.pending.count > 0 {
			command := next.pending.commands[next.pending.head]
			if command.sequence != ack && !replication.sequence_newer(ack, command.sequence) {break}
			_, _ = input_queue_pop(&next.pending)
		}
		next.last_ack, next.has_ack = ack, true
	}
	next.position = authoritative
	for index in 0..<next.pending.count {
		command := next.pending.commands[(next.pending.head + index) % INPUT_HISTORY_CAPACITY]
		next.position = move_position(next.position, command.axis, MOVE_DT)
	}
	next.ready = true
	state^ = next
	return true
}

// Presentation state never replaces authoritative ECS transforms. Remote
// players move between snapshots; the local player retains immediate inputs.
Remote_Smoothing :: struct {
	initialized: bool,
	position, start, target: [2]f32,
	elapsed: f32,
}

remote_target :: proc(remote: ^Remote_Smoothing, position: [2]f32) {
	if remote == nil || !prediction_position_valid(position) {return}
	difference := position - remote.position
	if !remote.initialized || difference[0]*difference[0] + difference[1]*difference[1] > PRESENTATION_SNAP_DISTANCE*PRESENTATION_SNAP_DISTANCE {
		remote^ = {initialized = true, position = position, start = position, target = position, elapsed = SMOOTH_INTERVAL}
		return
	}
	remote.start, remote.target, remote.elapsed = remote.position, position, 0
}

remote_advance :: proc(remote: ^Remote_Smoothing, dt: f32) {
	if remote == nil || !remote.initialized || !presentation_dt_valid(dt) {return}
	remote.elapsed = min(remote.elapsed + min(dt, SMOOTH_INTERVAL), SMOOTH_INTERVAL)
	amount := remote.elapsed / SMOOTH_INTERVAL
	remote.position = clamp_position(remote.start + (remote.target - remote.start) * amount)
	if remote.elapsed == SMOOTH_INTERVAL {remote.position = remote.target}
}

Correction_Smoothing :: struct {offset: [2]f32}

correction_set :: proc(correction: ^Correction_Smoothing, before, after: [2]f32) {
	if correction == nil || !prediction_position_valid(before) || !prediction_position_valid(after) {return}
	difference := before - after
	if difference[0]*difference[0] + difference[1]*difference[1] > PRESENTATION_SNAP_DISTANCE*PRESENTATION_SNAP_DISTANCE {
		correction.offset = {}
	} else {
		correction.offset = difference
	}
}

correction_advance :: proc(correction: ^Correction_Smoothing, dt: f32) {
	if correction == nil || !presentation_dt_valid(dt) {return}
	// Use a wide exponent so every finite f32 duration decays safely.
	correction.offset *= f32(math.exp(-f64(CORRECTION_DECAY) * f64(dt)))
}

correction_position :: proc(correction: Correction_Smoothing, position: [2]f32) -> [2]f32 {
	return clamp_position(position + correction.offset)
}
