package main

import "core:fmt"
import "core:time"
import "rune:ecs"
import "rune:network"
import "rune:replication"

PLAYER_SIZE :: f32(36)
ARENA_MIN :: [2]f32{58, 198}
ARENA_MAX :: [2]f32{902, 582}
PLAYER_SPEED :: f32(180)
INPUT_TIMEOUT :: f32(0.25)
GUEST_INPUT_CREDIT_LIMIT :: INPUT_HISTORY_CAPACITY
GUEST_INPUT_STEPS_PER_TICK :: 8
JOIN_TIMEOUT :: 5 * time.Second
STEP :: time.Second / 60

Game_Status :: enum {Waiting, Playing, Closed, Failed}
Game_State :: struct {
	client: network.Client,
	replica: replication.Replica,
	local_peer: u32,
	room_code: [network.CODE_SIZE]u8,
	tick, fixed_ticks, next_entity_id, guest_peer: u32,
	guest_axis, local_axis: [2]i8,
	guest_sequence, input_sequence: u32,
	has_guest_sequence: bool,
	guest_input_age: f32,
	guest_inputs: Input_Queue,
	guest_input_credit: int,
	guest_input_clock: time.Tick,
	guest_input_remainder: time.Duration,
	guest_applied_sequence: u32,
	has_guest_ack: bool,
	prediction: Prediction_State,
	correction: Correction_Smoothing,
	remote: Remote_Smoothing,
	remote_id: u32,
	peer_stats: Peer_Stats,
	rates: Game_Rates,
	snapshots_received, inputs_received, inputs_sent, snapshots_sent, rejected_messages: u64,
	status: Game_Status,
	message: string,
	hosting, scripted: bool,
	started: time.Tick,
}

game_state: Game_State

game_fail :: proc(state: ^Game_State, world: ^ecs.World, message: string) {
	state.status, state.message = .Failed, message
	fmt.eprintln(message)
	network.disconnect(&state.client)
	replication.clear(&state.replica, world)
	game_clear_motion(state)
}

game_clear_motion :: proc(state: ^Game_State) {
	state.guest_inputs = {}
	state.guest_input_credit = 0
	state.guest_input_clock = {}
	state.guest_input_remainder = 0
	state.guest_applied_sequence = 0
	state.has_guest_ack = false
	state.prediction = {}
	state.correction = {}
	state.remote = {}
	state.remote_id = 0
	state.peer_stats = {}
	state.rates = {}
}

game_remote_target :: proc(state: ^Game_State, snapshot: replication.Snapshot) {
	snapshot := snapshot
	for player in snapshot.states[:snapshot.count] {
		if player.owner_peer == state.local_peer {continue}
		if state.remote_id != player.id {state.remote = {}; state.remote_id = player.id}
		remote_target(&state.remote, player.position)
	}
}

game_visual_update :: proc(state: ^Game_State, dt: f32) {
	remote_advance(&state.remote, dt)
	correction_advance(&state.correction, dt)
}

// Presentation never changes authoritative physics or prediction history.
game_render_position :: proc(state: ^Game_State, identity: replication.Identity, position: [2]f32) -> [2]f32 {
	// The host already simulates both players at 60 Hz. Only a guest needs
	// to interpolate positions received in 20 Hz network snapshots.
	if state.hosting {return position}
	if identity.owner_peer == state.local_peer {
		return correction_position(state.correction, position)
	}
	if identity.id == state.remote_id && state.remote.initialized {return state.remote.position}
	return position
}

game_set_predicted_position :: proc(state: ^Game_State, world: ^ecs.World) -> bool {
	for index in 0..<state.replica.count {
		if state.replica.owner_peers[index] != state.local_peer {continue}
		entity := state.replica.entities[index]
		transform, valid := ecs.get_transform(world, entity)
		if !valid {return false}
		transform.position.x, transform.position.y = state.prediction.position.x, state.prediction.position.y
		return ecs.set_transform(world, entity, transform)
	}
	return false
}

// Network IDs are independent of local ECS handles and are never recycled in
// a room, including when a new guest replaces the previous guest.
game_add_player :: proc(state: ^Game_State, world: ^ecs.World, registry: ^ecs.Component_Registry, peer: u32, position: [2]f32) -> bool {
	snapshot, valid := replication.snapshot_from_world(world, state.tick + 1)
	if !valid || snapshot.count >= 2 || state.next_entity_id == 0 {return false}
	snapshot.states[snapshot.count] = {id = state.next_entity_id, owner_peer = peer, position = position}
	snapshot.count += 1
	if !replication.apply_snapshot(&state.replica, world, registry, snapshot) {return false}
	state.next_entity_id += 1
	state.tick = snapshot.tick
	return true
}

game_remove_player :: proc(state: ^Game_State, world: ^ecs.World, registry: ^ecs.Component_Registry, peer: u32) -> bool {
	current, valid := replication.snapshot_from_world(world, state.tick + 1)
	if !valid {return false}
	snapshot := replication.Snapshot{tick = current.tick}
	for player in current.states[:current.count] {
		if player.owner_peer != peer {
			snapshot.states[snapshot.count] = player
			snapshot.count += 1
		}
	}
	if !replication.apply_snapshot(&state.replica, world, registry, snapshot) {return false}
	state.tick = snapshot.tick
	return true
}

game_send_snapshot :: proc(state: ^Game_State, world: ^ecs.World, target: u32 = 0) -> bool {
	snapshot, valid := replication.snapshot_from_world(world, state.tick)
	if !valid {return false}
	bytes: [MAX_GAME_SNAPSHOT_SIZE]u8
	size, encoded := encode_game_snapshot({snapshot = snapshot, ack = state.guest_applied_sequence, has_ack = state.has_guest_ack}, bytes[:])
	if !encoded || !network.send(&state.client, bytes[:size], target) {return false}
	state.snapshots_sent += 1
	return true
}

game_snapshot_valid :: proc(state: ^Game_State, value: replication.Snapshot) -> bool {
	if value.count != 2 || !replication.snapshot_valid(value) {return false}
	snapshot := value
	hosts, guests := 0, 0
	for player in snapshot.states[:snapshot.count] {
		if player.owner_peer == 1 {hosts += 1}
		else if player.owner_peer == state.local_peer {guests += 1}
		else {return false}
		if player.position[0] < ARENA_MIN[0] || player.position[0] > ARENA_MAX[0] ||
		   player.position[1] < ARENA_MIN[1] || player.position[1] > ARENA_MAX[1] {return false}
	}
	return hosts == 1 && guests == 1
}

game_pump :: proc(state: ^Game_State, world: ^ecs.World, registry: ^ecs.Component_Registry) {
	if state.status == .Closed || state.status == .Failed {return}
	for _ in 0..<64 {
		packet, available, ok := network.poll(&state.client)
		if !ok {
			message := "UDP connection failed. Check the relay's UDP port and firewall." if state.client.udp_failed else "Connection to the relay was lost."
			game_fail(state, world, message); return
		}
		if !available {break}
		#partial switch packet.kind {
		case .Welcome, .Joined:
			state.local_peer = state.client.peer_id
			state.room_code = state.client.room_code
			state.status = .Playing
			state.message = "Waiting for a guest." if state.hosting else "Waiting for the host's scene."
			state.next_entity_id = 1
			if state.hosting && !game_add_player(state, world, registry, 1, {320, 400}) {
				game_fail(state, world, "Could not create the host player."); return
			}
			fmt.printf("Room: %s peer=%d role=%s\n", string(state.room_code[:]), state.local_peer, "host" if state.hosting else "guest")
		case .Peer_Joined:
			if state.hosting {
				if state.guest_peer != 0 || packet.peer == 1 || !game_add_player(state, world, registry, packet.peer, {640, 400}) {
					game_fail(state, world, "Could not create the guest player."); return
				}
				state.guest_peer = packet.peer
				state.guest_axis = {}
				state.has_guest_sequence = false
				state.guest_input_age = INPUT_TIMEOUT
				game_clear_motion(state)
				state.guest_input_clock = time.tick_now()
				state.message = "Both players are connected."
				fmt.printf("Guest joined: peer=%d network_id=%d\n", packet.peer, state.next_entity_id - 1)
				if !game_send_snapshot(state, world, packet.peer) {game_fail(state, world, "Could not send the starting scene."); return}
			}
		case .Peer_Left:
			if state.hosting && packet.peer == state.guest_peer {
				if !game_remove_player(state, world, registry, packet.peer) {game_fail(state, world, "Could not remove the departing player."); return}
				state.guest_peer = 0
				state.guest_axis = {}
				state.has_guest_sequence = false
				game_clear_motion(state)
				state.message = "Guest left. Another player can join with the same code."
				fmt.printf("Guest left: peer=%d players=%d\n", packet.peer, state.replica.count)
			}
		case .Data:
			remote_peer := state.guest_peer if state.hosting else u32(1)
			recognized, valid_probe, probe_ok := peer_stats_receive(&state.peer_stats, &state.client, remote_peer, packet, time.tick_now())
			if !probe_ok {game_fail(state, world, "The connection could not send a ping reply."); return}
			if recognized {
				if !valid_probe {state.rejected_messages += 1}
				continue
			}
			if state.hosting {
				if packet.peer != state.guest_peer || state.guest_peer == 0 {
					state.rejected_messages += 1; continue
				}
				if !game_receive_input(state, world, packet.payload[:packet.payload_size]) {return}
			} else {
				value, valid := decode_game_snapshot(packet.payload[:packet.payload_size])
				snapshot := value.snapshot
				if packet.peer != 1 || !valid || !game_snapshot_valid(state, snapshot) {
					state.rejected_messages += 1; continue
				}
				local_position: [2]f32
				for player in snapshot.states[:snapshot.count] {
					if player.owner_peer == state.local_peer {local_position = player.position}
				}
				// Preview the acknowledgement and replay before changing the ECS.
				next_prediction := state.prediction
				if !prediction_reconcile(&next_prediction, local_position, value.ack, value.has_ack) ||
				   !replication.apply_snapshot(&state.replica, world, registry, snapshot) {
					state.rejected_messages += 1; continue
				}
				before := correction_position(state.correction, state.prediction.position) if state.prediction.ready else next_prediction.position
				state.prediction = next_prediction
				assert(game_set_predicted_position(state, world))
				correction_set(&state.correction, before, state.prediction.position)
				game_remote_target(state, snapshot)
				state.tick = snapshot.tick
				state.snapshots_received += 1
				state.message = "Both players are connected."
			}
		case .Room_Closed:
			replication.clear(&state.replica, world)
			game_clear_motion(state)
			state.status, state.message = .Closed, "The host closed the room."
			fmt.println("Host closed room; replicated players cleared.")
			return
		case .Error:
			code := network.Error_Code(packet.payload[0])
			fmt.eprintln("Relay error:", code)
			message := "The relay rejected the request. Please try again."
			#partial switch code {
			case .Room_Not_Found: message = "No room was found for that code. Check it and try again."
			case .Room_Full: message = "That room is full. Ask the host for another room."
			case .Server_Full: message = "The relay has no room available. Try again shortly."
			}
			game_fail(state, world, message)
			return
		}
	}
	if state.status == .Waiting && time.tick_since(state.started) >= JOIN_TIMEOUT {
		game_fail(state, world, "Room creation or joining timed out.")
	}
}

game_receive_input :: proc(state: ^Game_State, world: ^ecs.World, payload: []u8) -> bool {
	// Keep the shared single-command format available for existing TCP callers.
	if len(payload) == replication.INPUT_SIZE {
		command, valid := replication.decode_input(payload)
		if !valid || (state.has_guest_sequence && !replication.sequence_newer(command.sequence, state.guest_sequence)) {
			state.rejected_messages += 1; return true
		}
		if !input_queue_push(&state.guest_inputs, command) {
			game_fail(state, world, "The host could not keep up with guest input."); return false
		}
		state.guest_axis, state.guest_sequence = command.axis, command.sequence
		state.has_guest_sequence, state.guest_input_age = true, 0
		state.inputs_received += 1
		return true
	}
	batch, valid := decode_game_input(payload)
	if !valid {state.rejected_messages += 1; return true}
	next := state.guest_inputs
	sequence := state.guest_sequence if state.has_guest_sequence else u32(0)
	accepted := 0
	for command in batch.commands[:batch.count] {
		expected := sequence + 1
		if command.sequence != expected {
			// A missing prefix is repaired by the next redundant batch. Never
			// acknowledge across that gap, or an unexecuted step would be lost.
			if replication.sequence_newer(command.sequence, expected) {return true}
			continue
		}
		if !input_queue_push(&next, command) {
			game_fail(state, world, "The host could not keep up with guest input."); return false
		}
		sequence = command.sequence
		accepted += 1
	}
	if accepted > 0 {
		state.guest_inputs = next
		state.guest_sequence, state.guest_axis = sequence, batch.commands[batch.count-1].axis
		state.has_guest_sequence = true
		state.inputs_received += u64(accepted)
	}
	// An authenticated repeat is normal while snapshots are lost. It keeps
	// the input history alive but grants neither movement time nor a new ack.
	state.guest_input_age = 0
	return true
}

// Input time follows the host's monotonic clock, independently of rendering's
// clamped frame delta. A host window stall must not permanently put its guest
// behind. Retain bounded unused time even while packets are missing, so a
// later redundant batch can recover that history without a permanent delay.
game_advance_input_clock :: proc(state: ^Game_State, now: time.Tick) {
	if state.guest_peer == 0 {return}
	if state.guest_input_clock == (time.Tick{}) {state.guest_input_clock = now; return}
	elapsed := time.tick_diff(state.guest_input_clock, now)
	if elapsed < 0 {return}
	state.guest_input_clock = now
	state.guest_input_remainder += min(elapsed, time.Duration(GUEST_INPUT_CREDIT_LIMIT)*STEP)
	steps := int(state.guest_input_remainder / STEP)
	state.guest_input_remainder %= STEP
	state.guest_input_credit = min(state.guest_input_credit + steps, GUEST_INPUT_CREDIT_LIMIT)
}

game_fixed_update :: proc(state: ^Game_State, world: ^ecs.World, dt: f32, input_now: time.Tick = {}) {
	if state.status != .Playing {return}
	state.fixed_ticks += 1
	if state.hosting {
		input_now := input_now
		if input_now == (time.Tick{}) {input_now = time.tick_now()}
		game_advance_input_clock(state, input_now)
		state.tick += 1
		state.guest_input_age += dt
		guest_steps: [GUEST_INPUT_STEPS_PER_TICK]replication.Input_Command
		guest_step_count := 0
		if state.guest_peer == 0 || (state.has_guest_sequence && state.guest_input_age >= INPUT_TIMEOUT) {
			state.guest_inputs = {}
			// A dropped receive queue is still unacknowledged. Permit the guest
			// to repeat its prefix instead of permanently ignoring those steps.
			state.guest_sequence = state.guest_applied_sequence
			state.has_guest_sequence = state.has_guest_ack
			state.guest_axis = {}
		} else {
			// Spend elapsed host time, including time lost to a window stall.
			// Receipt alone never grants movement time or an acknowledgement.
			for guest_step_count < GUEST_INPUT_STEPS_PER_TICK && state.guest_input_credit > 0 {
				command, available := input_queue_pop(&state.guest_inputs)
				if !available {break}
				guest_steps[guest_step_count] = command
				guest_step_count += 1
				state.guest_input_credit -= 1
			}
		}
		for entity in ecs.query2(world, replication.Identity, ecs.Transform) {
			identity, _ := ecs.get(world, entity, replication.Identity)
			transform, _ := ecs.get(world, entity, ecs.Transform)
			position := [2]f32{transform.position.x, transform.position.y}
			if identity.owner_peer == 1 {
				position = move_position(position, state.local_axis, MOVE_DT)
			} else {
				if identity.owner_peer != state.guest_peer || guest_step_count == 0 {continue}
				for command in guest_steps[:guest_step_count] {
					position = move_position(position, command.axis, MOVE_DT)
				}
			}
			transform.position.x, transform.position.y = position.x, position.y
			if !ecs.set_transform(world, entity, transform) {game_fail(state, world, "Could not update a player transform."); return}
		}
		if guest_step_count > 0 {
			guest_step := guest_steps[guest_step_count - 1]
			state.guest_axis = guest_step.axis
			state.guest_applied_sequence = guest_step.sequence
			state.has_guest_ack = true
		}
		if state.guest_peer != 0 && state.fixed_ticks % 3 == 0 && !game_send_snapshot(state, world) {
			game_fail(state, world, "The connection could not keep up with scene updates.")
		}
	} else if state.prediction.ready {
		command := replication.Input_Command{sequence = state.input_sequence + 1, axis = state.local_axis}
		next_prediction := state.prediction
		if !prediction_record(&next_prediction, command) {
			game_fail(state, world, "The host could not keep up with predicted movement."); return
		}
		bytes: [MAX_GAME_INPUT_SIZE]u8
		size, valid := encode_game_input(game_pending_input(&next_prediction), bytes[:])
		if !valid || !network.send(&state.client, bytes[:size], 1) {
			game_fail(state, world, "The connection could not keep up with movement input."); return
		}
		state.input_sequence = command.sequence
		state.prediction = next_prediction
		if !game_set_predicted_position(state, world) {game_fail(state, world, "Could not predict the local player."); return}
		state.inputs_sent += 1
	}
}

scripted_axis :: proc(state: ^Game_State) -> [2]i8 {
	phase := int(time.tick_since(state.started) / time.Second) % 4
	directions := [4][2]i8{{1,0}, {0,1}, {-1,0}, {0,-1}}
	if !state.hosting {directions = {{0,1}, {-1,0}, {0,-1}, {1,0}}}
	return directions[phase]
}

log_game :: proc(state: ^Game_State, world: ^ecs.World) {
	fmt.printf("State: role=%s tick=%d players=%d inputs=%d snapshots=%d rejected=%d pending=%d ack=%d transport=%s udp_sent=%d udp_received=%d\n", "host" if state.hosting else "guest", state.tick, state.replica.count,
		state.inputs_received if state.hosting else state.inputs_sent, state.snapshots_sent if state.hosting else state.snapshots_received, state.rejected_messages,
		state.guest_inputs.count if state.hosting else state.prediction.pending.count,
		state.guest_applied_sequence if state.hosting else state.prediction.last_ack,
		"disconnected" if state.client.status == .Disconnected else ("udp" if state.client.udp_ready else ("udp-pending" if state.client.udp_requested else "tcp")),
		state.client.udp_datagrams_sent, state.client.udp_datagrams_received)
	stats := network.stats(&state.client)
	fmt.printf("Network: peer_rtt_ms=%.2f relay_rtt_ms=%.2f jitter_ms=%.2f rx_loss_percent=%.2f tx_bytes_per_second=%.0f rx_bytes_per_second=%.0f tx_packets_per_second=%.0f rx_packets_per_second=%.0f probe_timeouts=%d duplicates=%d reordered=%d invalid=%d local_dropped=%d\n",
		state.peer_stats.rtt_ms if state.peer_stats.has_rtt else -1,
		stats.relay_rtt_ms if stats.has_relay_rtt else -1,
		state.peer_stats.jitter_ms if state.peer_stats.has_rtt else -1,
		stats.udp_rx_loss_percent if stats.udp_rx_expected > 0 && state.client.udp_requested else -1,
		stats.tx_bytes_per_second, stats.rx_bytes_per_second, stats.tx_packets_per_second, stats.rx_packets_per_second, state.peer_stats.probes_timed_out,
		stats.udp_duplicates, stats.udp_reordered, stats.udp_invalid, stats.udp_local_dropped)
	for entity in ecs.query2(world, replication.Identity, ecs.Transform) {
		identity, _ := ecs.get(world, entity, replication.Identity)
		transform, _ := ecs.get(world, entity, ecs.Transform)
		fmt.printf("Player: id=%d owner=%d x=%.2f y=%.2f\n", identity.id, identity.owner_peer, transform.position[0], transform.position[1])
	}
}

game_cleanup :: proc(state: ^Game_State, world: ^ecs.World) {
	network.disconnect(&state.client)
	replication.clear(&state.replica, world)
	game_clear_motion(state)
}
