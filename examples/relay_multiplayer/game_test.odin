package main

import "core:net"
import "core:testing"
import "core:time"
import relay "../../rune_relay/server"
import "rune:ecs"
import "rune:network"
import "rune:replication"

Game_Test_Fixture :: struct {
	server: relay.Server,
	registry: ecs.Component_Registry,
	world: ecs.World,
	host: Game_State,
	guest: network.Client,
	guest_snapshot_packets: int,
}

test_drain_client :: proc(client: ^network.Client) -> int {
	data := 0
	for _ in 0..<64 {
		packet, available, ok := network.poll(client)
		assert(ok && (!available || packet.kind != .Error))
		if !available {return data}
		if packet.kind == .Data {data += 1}
	}
	return data
}

test_join_guest :: proc(fixture: ^Game_Test_Fixture) {
	assert(network.connect(&fixture.guest, net.endpoint_to_string(fixture.server.endpoint)) == nil)
	assert(network.join_room(&fixture.guest, string(fixture.host.room_code[:])))
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		fixture.guest_snapshot_packets += test_drain_client(&fixture.guest)
		if fixture.guest.status == .In_Room && fixture.host.guest_peer == fixture.guest.peer_id {return}
		time.sleep(time.Millisecond)
	}
	assert(false, "guest could not join the test host")
}

test_init_game :: proc(fixture: ^Game_Test_Fixture) {
	fixture.registry = ecs.init_registry()
	assert(ecs.register_builtin_components(&fixture.registry) && replication.register(&fixture.registry))
	fixture.world = ecs.init()
	assert(relay.server_start(&fixture.server, {listen={address=net.IP4_Loopback, port=0}, max_connections=4, max_rooms=1}) == "")
	fixture.host = {hosting=true, status=.Waiting, started=time.tick_now()}
	assert(network.connect(&fixture.host.client, net.endpoint_to_string(fixture.server.endpoint)) == nil)
	assert(network.create_room(&fixture.host.client, 2))
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		if fixture.host.client.status == .In_Room {break}
		time.sleep(time.Millisecond)
	}
	assert(fixture.host.client.status == .In_Room && fixture.host.replica.count == 1)
	test_join_guest(fixture)
	assert(fixture.host.status == .Playing && fixture.host.replica.count == 2)
	// Consume the joining snapshot before a test supplies its own guest world.
	draining := time.tick_now()
	for fixture.guest_snapshot_packets < 1 && time.tick_since(draining) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		fixture.guest_snapshot_packets += test_drain_client(&fixture.guest)
		time.sleep(time.Millisecond)
	}
	assert(fixture.guest_snapshot_packets == 1, "joining guest did not receive its initial snapshot")
}

test_destroy_game :: proc(fixture: ^Game_Test_Fixture) {
	network.disconnect(&fixture.guest)
	game_cleanup(&fixture.host, &fixture.world)
	relay.server_stop(&fixture.server)
	ecs.destroy(&fixture.world)
	ecs.destroy_registry(&fixture.registry)
}

// Advance a deterministic monotonic clock instead of depending on how fast
// the test runner executes fixed updates.
test_host_step :: proc(fixture: ^Game_Test_Fixture, dt: f32 = MOVE_DT) {
	game_fixed_update(&fixture.host, &fixture.world, dt,
		time.tick_add(fixture.host.guest_input_clock, time.Duration(f64(dt)*f64(time.Second))))
}

test_player :: proc(fixture: ^Game_Test_Fixture, peer: u32) -> (ecs.Entity, ecs.Transform, replication.Identity) {
	for entity in ecs.query2(&fixture.world, replication.Identity, ecs.Transform) {
		identity, _ := ecs.get(&fixture.world, entity, replication.Identity)
		if identity.owner_peer != peer {continue}
		transform, _ := ecs.get_transform(&fixture.world, entity)
		return entity, transform, identity
	}
	assert(false, "test player not found")
	return {}, {}, {}
}

test_send_input :: proc(fixture: ^Game_Test_Fixture, sequence: u32, axis: [2]i8) {
	bytes: [replication.INPUT_SIZE]u8
	size, valid := replication.encode_input({sequence=sequence, axis=axis}, bytes[:])
	assert(valid && network.send(&fixture.guest, bytes[:size], 1))
}

test_wait_inputs :: proc(fixture: ^Game_Test_Fixture, accepted, rejected: u64) {
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		test_drain_client(&fixture.guest)
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		if fixture.host.inputs_received >= accepted && fixture.host.rejected_messages >= rejected {return}
		time.sleep(time.Millisecond)
	}
	assert(false, "host input events did not arrive")
}

test_receive_game_snapshot :: proc(fixture: ^Game_Test_Fixture) -> Game_Snapshot {
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		for _ in 0..<64 {
			packet, available, ok := network.poll(&fixture.guest)
			assert(ok && (!available || packet.kind != .Error))
			if !available {break}
			if packet.kind != .Data {continue}
			snapshot, valid := decode_game_snapshot(packet.payload[:packet.payload_size])
			assert(valid)
			return snapshot
		}
		time.sleep(time.Millisecond)
	}
	assert(false, "guest did not receive a game snapshot")
	return {}
}

@(test)
host_draws_guest_immediately_between_snapshots :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	entity, initial, identity := test_player(&fixture, fixture.guest.peer_id)
	// Even stale presentation history cannot delay a locally simulated actor.
	fixture.host.remote_id = identity.id
	remote_target(&fixture.host.remote, {initial.position.x, initial.position.y})
	test_send_input(&fixture, 1, {1,0})
	test_wait_inputs(&fixture, 1, 0)
	snapshots := fixture.host.snapshots_sent
	test_host_step(&fixture, MOVE_DT)
	position, _ := ecs.get_transform(&fixture.world, entity)
	rendered := game_render_position(&fixture.host, identity, {position.position.x, position.position.y})
	testing.expect(t, fixture.host.snapshots_sent == snapshots, "this movement occurs before the next outbound snapshot")
	testing.expect(t, rendered == [2]f32{initial.position.x + PLAYER_SPEED*MOVE_DT, initial.position.y},
		"the host draws the guest's new authoritative position on the same tick")
	guest := Game_State{local_peer=fixture.guest.peer_id, remote_id=1}
	remote_target(&guest.remote, {320,400})
	remote_target(&guest.remote, {329,400})
	testing.expect(t, game_render_position(&guest, {id=1, owner_peer=1}, {329,400}) == [2]f32{320,400},
		"the guest still interpolates the host's network snapshots")
}

@(test)
guest_delayed_batch_catches_up_while_new_commands_keep_arriving :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	entity, initial, _ := test_player(&fixture, fixture.guest.peer_id)
	for _ in 0..<3 {test_host_step(&fixture, MOVE_DT)}
	testing.expect(t, fixture.host.guest_input_credit == 3,
		"the host banks simulation steps while the guest is starting or input is in transit")
	for sequence: u32 = 1; sequence <= 3; sequence += 1 {test_send_input(&fixture, sequence, {1,0})}
	test_wait_inputs(&fixture, 3, 0)
	test_host_step(&fixture, MOVE_DT)
	testing.expect(t, fixture.host.guest_inputs.count == 0 && fixture.host.guest_applied_sequence == 3)
	test_send_input(&fixture, 4, {0,0}); test_wait_inputs(&fixture, 4, 0)
	test_host_step(&fixture, MOVE_DT)
	position, _ := ecs.get_transform(&fixture.world, entity)
	testing.expect(t, fixture.host.guest_inputs.count == 0 && fixture.host.guest_applied_sequence == 4,
		"a continuing 60 Hz input stream no longer preserves the initial queue delay")
	testing.expect(t, position.position.x == initial.position.x + 3*PLAYER_SPEED*MOVE_DT,
		"catchup applies each movement command once and reaches the newest stop command")
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	snapshot := test_receive_game_snapshot(&fixture)
	testing.expect(t, snapshot.has_ack && snapshot.ack == 4, "catchup acknowledges the last command actually simulated")
}

@(test)
guest_catchup_spends_bounded_host_time :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	entity, initial, _ := test_player(&fixture, fixture.guest.peer_id)
	for _ in 0..<30 {test_host_step(&fixture, MOVE_DT)}
	testing.expect(t, fixture.host.guest_input_credit == 30, "missing input retains only time actually elapsed on the host")
	for sequence: u32 = 1; sequence <= 30; sequence += 1 {test_send_input(&fixture, sequence, {1,0})}
	test_wait_inputs(&fixture, 30, 0)
	for index in 0..<12 {
		// Keep the stream fresh while attempting to outrun the host clock.
		test_send_input(&fixture, u32(31+index), {1,0})
		test_wait_inputs(&fixture, u64(31+index), 0)
		before := fixture.host.guest_applied_sequence
		test_host_step(&fixture, MOVE_DT)
		testing.expect(t, fixture.host.guest_applied_sequence-before <= GUEST_INPUT_STEPS_PER_TICK)
		testing.expect(t, fixture.host.guest_applied_sequence <= u32(30+index+1),
			"a burst cannot spend more movement time than the host banked and subsequently elapsed")
	}
	position, _ := ecs.get_transform(&fixture.world, entity)
	testing.expect(t, position.position.x == initial.position.x + f32(fixture.host.guest_applied_sequence)*PLAYER_SPEED*MOVE_DT)
	testing.expect(t, fixture.host.guest_input_credit == 0 && fixture.host.guest_applied_sequence == 42,
		"after consuming previously elapsed time, sustained input advances only at the host's rate")
}

@(test)
guest_backlog_recovers_after_host_loses_render_time :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	_, initial, _ := test_player(&fixture, fixture.guest.peer_id)
	for sequence: u32 = 1; sequence <= 40; sequence += 1 {test_send_input(&fixture, sequence, {1,0})}
	test_wait_inputs(&fixture, 40, 0)
	// Reproduce the user's persistent 40-command backlog: a second passes,
	// but rendering only supplies one ordinary fixed step after the stall.
	game_fixed_update(&fixture.host, &fixture.world, MOVE_DT,
		time.tick_add(fixture.host.guest_input_clock, time.Second))
	testing.expect(t, fixture.host.guest_applied_sequence == 8 && fixture.host.guest_inputs.count == 32 && fixture.host.guest_input_credit == 52,
		"the input budget includes wall time discarded by the renderer's delta clamp")
	for index in 0..<5 {
		test_send_input(&fixture, u32(41+index), {1,0})
		test_wait_inputs(&fixture, u64(41+index), 0)
		test_host_step(&fixture)
	}
	_, position, _ := test_player(&fixture, fixture.guest.peer_id)
	testing.expect(t, fixture.host.guest_inputs.count == 0 && fixture.host.guest_applied_sequence == 45,
		"a 40-command backlog drains while new commands continue at 60 Hz")
	testing.expect(t, position.position.x == initial.position.x + 45*PLAYER_SPEED*MOVE_DT,
		"recovery preserves every command and acknowledges only simulated movement")
	testing.expect(t, fixture.host.guest_input_credit == 20,
		"recovery spends only executed commands and retains the remaining elapsed time")
}

@(test)
guest_stall_resume_keeps_idle_reserve_through_timeout :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	test_send_input(&fixture, 1, {0,0}); test_wait_inputs(&fixture, 1, 0)
	test_host_step(&fixture)
	for _ in 0..<60 {test_host_step(&fixture)}
	testing.expect(t, fixture.host.guest_input_age >= INPUT_TIMEOUT && fixture.host.guest_input_credit == 60,
		"a quiet guest retains elapsed host time for a later loss-repair batch")
	for sequence: u32 = 2; sequence <= 9; sequence += 1 {test_send_input(&fixture, sequence, {0,1})}
	test_wait_inputs(&fixture, 9, 0)
	test_host_step(&fixture)
	testing.expect(t, fixture.host.guest_inputs.count == 0 && fixture.host.guest_applied_sequence == 9,
		"the guest's frame catchup batch does not create permanent delay after an input timeout")
}

@(test)
guest_input_budget_preserves_fractional_time_and_caps_recovery :: proc(t: ^testing.T) {
	state := Game_State{guest_peer=2, guest_input_clock=time.tick_now()}
	start := state.guest_input_clock
	game_advance_input_clock(&state, time.tick_add(start, STEP/2))
	testing.expect(t, state.guest_input_credit == 0)
	game_advance_input_clock(&state, time.tick_add(start, STEP))
	testing.expect(t, state.guest_input_credit == 1,
		"fractional frame intervals combine into one movement step")
	state.guest_inputs.count = 1
	game_advance_input_clock(&state, time.tick_add(start, 30*time.Second))
	testing.expect(t, state.guest_input_credit == GUEST_INPUT_CREDIT_LIMIT,
		"recovery credit is bounded even after a very long host stall")
	state.guest_inputs = {}
	game_advance_input_clock(&state, state.guest_input_clock)
	testing.expect(t, state.guest_input_credit == GUEST_INPUT_CREDIT_LIMIT,
		"an empty queue cannot erase the time needed to recover packets still in transit")
}

@(test)
guest_packet_burst_moves_once_per_fixed_step :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	guest_entity, initial, _ := test_player(&fixture, fixture.guest.peer_id)
	for sequence: u32 = 1; sequence <= 20; sequence += 1 {test_send_input(&fixture, sequence, {1,0})}
	test_wait_inputs(&fixture, 20, 0)
	before_step, _ := ecs.get_transform(&fixture.world, guest_entity)
	testing.expect(t, before_step.position == initial.position, "network input receipt must not advance the simulation")
	testing.expect(t, fixture.host.guest_inputs.count == 20 && !fixture.host.has_guest_ack)
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	received_only := test_receive_game_snapshot(&fixture)
	testing.expect(t, !received_only.has_ack && received_only.ack == 0,
		"receiving input cannot acknowledge commands the host has not simulated")
	test_host_step(&fixture, 1.0/60.0)
	after_step, _ := ecs.get_transform(&fixture.world, guest_entity)
	testing.expect(t, after_step.position.x == initial.position.x + PLAYER_SPEED*MOVE_DT && after_step.position.y == initial.position.y,
		"twenty queued commands still allow only one fixed step of movement")
	testing.expect(t, fixture.host.has_guest_ack && fixture.host.guest_applied_sequence == 1 && fixture.host.guest_inputs.count == 19)
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	applied_one := test_receive_game_snapshot(&fixture)
	testing.expect(t, applied_one.has_ack && applied_one.ack == 1 && fixture.host.guest_sequence == 20,
		"the snapshot acknowledges the consumed command rather than the newest received command")
	// Duplicates, out-of-order commands and invalid axes cannot enter the queue.
	test_send_input(&fixture, 20, {-1,0})
	test_send_input(&fixture, 19, {-1,0})
	malformed: [replication.INPUT_SIZE]u8
	_, valid := replication.encode_input({sequence=21, axis={1,0}}, malformed[:])
	assert(valid)
	malformed[6] = 127
	assert(network.send(&fixture.guest, malformed[:], 1))
	test_wait_inputs(&fixture, 20, 3)
	testing.expect(t, fixture.host.guest_sequence == 20 && fixture.host.guest_axis == [2]i8{1,0} && fixture.host.inputs_received == 20)
	test_host_step(&fixture, 1.0/60.0)
	after_second_step, _ := ecs.get_transform(&fixture.world, guest_entity)
	testing.expect(t, after_second_step.position.x == initial.position.x + 2*PLAYER_SPEED*MOVE_DT)
	testing.expect(t, fixture.host.guest_applied_sequence == 2 && fixture.host.guest_inputs.count == 18)
}

@(test)
guest_input_expiry_stops_movement_and_new_input_resumes :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	entity, initial, _ := test_player(&fixture, fixture.guest.peer_id)
	for sequence: u32 = 1; sequence <= 20; sequence += 1 {test_send_input(&fixture, sequence, {1,0})}
	test_wait_inputs(&fixture, 20, 0)
	test_host_step(&fixture, 0.05)
	moved, _ := ecs.get_transform(&fixture.world, entity)
	testing.expect(t, moved.position.x == initial.position.x + 3*PLAYER_SPEED*MOVE_DT,
		"50 milliseconds of host time pays for exactly three fixed movement commands")
	testing.expect(t, fixture.host.guest_inputs.count == 17 && fixture.host.guest_applied_sequence == 3)
	test_host_step(&fixture, 0.20)
	stopped, _ := ecs.get_transform(&fixture.world, entity)
	testing.expect(t, fixture.host.guest_input_age >= INPUT_TIMEOUT && stopped.position == moved.position,
		"input expiry discards queued movement at 250 milliseconds")
	testing.expect(t, fixture.host.guest_inputs.count == 0 && fixture.host.guest_input_credit == 12 && fixture.host.guest_applied_sequence == 3,
		"discarded commands cannot be acknowledged as simulated")
	test_send_input(&fixture, 21, {-1,0}); test_wait_inputs(&fixture, 21, 0)
	test_host_step(&fixture, 0.05)
	resumed, _ := ecs.get_transform(&fixture.world, entity)
	testing.expect(t, resumed.position.x == initial.position.x + 2*PLAYER_SPEED*MOVE_DT && fixture.host.status == .Playing)
	test_host_step(&fixture, MOVE_DT)
	no_command, _ := ecs.get_transform(&fixture.world, entity)
	testing.expect(t, no_command.position == resumed.position && fixture.host.guest_applied_sequence == 21,
		"held movement requires new commands rather than repeating an already consumed command")
}

@(test)
guest_leave_and_rejoin_preserve_host_and_assign_fresh_ids :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	host_entity, _, host_identity := test_player(&fixture, 1)
	old_peer := fixture.guest.peer_id
	old_entity, _, old_identity := test_player(&fixture, old_peer)
	test_send_input(&fixture, 1, {1,0}); test_send_input(&fixture, 2, {1,0})
	test_wait_inputs(&fixture, 2, 0)
	test_host_step(&fixture, MOVE_DT)
	assert(fixture.host.has_guest_ack && fixture.host.guest_inputs.count == 1)
	network.disconnect(&fixture.guest)
	started := time.tick_now()
	for fixture.host.guest_peer != 0 && time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		time.sleep(time.Millisecond)
	}
	testing.expect(t, fixture.host.guest_peer == 0 && fixture.host.replica.count == 1 && !ecs.is_alive(&fixture.world, old_entity))
	testing.expect(t, fixture.host.guest_inputs.count == 0 && fixture.host.guest_input_credit == 0 && !fixture.host.has_guest_ack && fixture.host.guest_applied_sequence == 0,
		"departing guests cannot leave movement or acknowledgements for their replacement")
	test_join_guest(&fixture)
	new_host_entity, _, new_host_identity := test_player(&fixture, 1)
	new_entity, _, new_identity := test_player(&fixture, fixture.guest.peer_id)
	testing.expect(t, fixture.guest.peer_id != old_peer && new_identity.id > old_identity.id && new_entity != old_entity)
	testing.expect(t, new_host_entity == host_entity && new_host_identity == host_identity && fixture.host.replica.count == 2)
	testing.expect(t, !fixture.host.has_guest_sequence && fixture.host.guest_axis == [2]i8{} && fixture.host.guest_input_age >= INPUT_TIMEOUT)
	testing.expect(t, fixture.host.guest_inputs.count == 0 && fixture.host.guest_input_credit == 0 && !fixture.host.has_guest_ack && fixture.host.guest_applied_sequence == 0)
}

test_wait_guest :: proc(fixture: ^Game_Test_Fixture, guest: ^Game_State, world: ^ecs.World, accepted, rejected: u64) {
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		if fixture.host.client.status != .Disconnected {game_pump(&fixture.host, &fixture.world, &fixture.registry)}
		game_pump(guest, world, &fixture.registry)
		if guest.snapshots_received >= accepted && guest.rejected_messages >= rejected {return}
		time.sleep(time.Millisecond)
	}
	assert(false, "guest snapshot events did not arrive")
}

test_guest_transform :: proc(guest: ^Game_State, world: ^ecs.World) -> ecs.Transform {
	for index in 0..<guest.replica.count {
		if guest.replica.owner_peers[index] != guest.local_peer {continue}
		transform, valid := ecs.get_transform(world, guest.replica.entities[index])
		assert(valid)
		return transform
	}
	assert(false, "predicted guest entity not found")
	return {}
}

@(test)
guest_predicts_before_roundtrip_and_reconciles_only_simulated_commands :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	world := ecs.init(); defer ecs.destroy(&world)
	guest := Game_State{client = fixture.guest, local_peer = fixture.guest.peer_id, status = .Playing, started = time.tick_now()}
	fixture.guest = {}
	defer game_cleanup(&guest, &world)
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	test_wait_guest(&fixture, &guest, &world, 1, 0)
	initial := test_guest_transform(&guest, &world)
	guest.local_axis = {1, 0}
	// Do not pump the relay or host while the guest produces three commands.
	for _ in 0..<3 {game_fixed_update(&guest, &world, MOVE_DT)}
	predicted := test_guest_transform(&guest, &world)
	testing.expect(t, predicted.position.x == initial.position.x + 3*PLAYER_SPEED*MOVE_DT && predicted.position.y == initial.position.y,
		"local fixed steps update the guest before any input or snapshot roundtrip")
	testing.expect(t, guest.inputs_sent == 3 && guest.prediction.pending.count == 3 && guest.snapshots_received == 1 && fixture.host.inputs_received == 0)
	started := time.tick_now()
	for fixture.host.inputs_received < 3 && time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		game_pump(&guest, &world, &fixture.registry)
		time.sleep(time.Millisecond)
	}
	assert(fixture.host.inputs_received == 3 && fixture.host.guest_inputs.count == 3 && !fixture.host.has_guest_ack)
	test_host_step(&fixture, MOVE_DT)
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	test_wait_guest(&fixture, &guest, &world, 2, 0)
	after_ack := test_guest_transform(&guest, &world)
	testing.expect(t, guest.prediction.has_ack && guest.prediction.last_ack == 1 && guest.prediction.pending.count == 2)
	testing.expect(t, after_ack.position == predicted.position,
		"the authoritative first step plus replayed commands two and three equals immediate prediction")
	// A newer frame may acknowledge the same consumed command. Rebuild from
	// its authoritative position instead of adding replay to the current guess.
	fixture.host.tick += 1
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	test_wait_guest(&fixture, &guest, &world, 3, 0)
	after_repeat := test_guest_transform(&guest, &world)
	testing.expect(t, after_repeat.position == predicted.position && guest.prediction.pending.count == 2 && guest.prediction.last_ack == 1,
		"repeated acknowledgements replay each outstanding command once per authoritative frame")
	version := ecs.change_version(&world)
	replica, prediction, correction, remote := guest.replica, guest.prediction, guest.correction, guest.remote
	valid_snapshot, captured := replication.snapshot_from_world(&fixture.world, fixture.host.tick+1)
	assert(captured)
	for invalid_case in 0..<4 {
		value := Game_Snapshot{snapshot = valid_snapshot, ack = 1, has_ack = true}
		switch invalid_case {
		case 0: value.ack = 4 // future acknowledgement beyond every sent command
		case 1: value.ack = 0 // acknowledgement regresses behind the accepted one
		case 2: value.ack, value.has_ack = 0, false // cannot erase accepted acknowledgement history
		case 3: value.snapshot.tick = guest.tick // stale authoritative frame
		}
		bytes: [MAX_GAME_SNAPSHOT_SIZE]u8
		size, encoded := encode_game_snapshot(value, bytes[:])
		assert(encoded && network.send(&fixture.host.client, bytes[:size]))
		test_wait_guest(&fixture, &guest, &world, 3, u64(invalid_case+1))
		testing.expect(t, guest.replica == replica && guest.prediction == prediction && guest.correction == correction && guest.remote == remote &&
			ecs.change_version(&world) == version && guest.snapshots_received == 3,
			"invalid acknowledgements or stale frames cannot partially alter simulation, replay, or presentation")
	}
}

@(test)
guest_prediction_reconciles_two_command_catchup :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	world := ecs.init(); defer ecs.destroy(&world)
	guest := Game_State{client=fixture.guest, local_peer=fixture.guest.peer_id, status=.Playing, started=time.tick_now()}
	fixture.guest = {}
	defer game_cleanup(&guest, &world)
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	test_wait_guest(&fixture, &guest, &world, 1, 0)
	for axis in ([3][2]i8{{1,0}, {0,1}, {-1,0}}) {
		guest.local_axis = axis
		game_fixed_update(&guest, &world, MOVE_DT)
	}
	predicted := test_guest_transform(&guest, &world)
	started := time.tick_now()
	for fixture.host.inputs_received < 3 && time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		time.sleep(time.Millisecond)
	}
	assert(fixture.host.inputs_received == 3)
	fixture.host.guest_input_credit = 1
	test_host_step(&fixture, MOVE_DT)
	assert(fixture.host.guest_applied_sequence == 2 && game_send_snapshot(&fixture.host, &fixture.world))
	test_wait_guest(&fixture, &guest, &world, 2, 0)
	after := test_guest_transform(&guest, &world)
	testing.expect(t, guest.prediction.last_ack == 2 && guest.prediction.pending.count == 1 && after.position == predicted.position,
		"a two-command catchup removes exactly those commands and replays the remaining mixed-direction step")
	fixture.host.tick += 1
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	test_wait_guest(&fixture, &guest, &world, 3, 0)
	repeated := test_guest_transform(&guest, &world)
	testing.expect(t, guest.prediction.pending.count == 1 && repeated.position == predicted.position,
		"repeating the catchup acknowledgement cannot apply the pending movement twice")
}

@(test)
guest_rejects_invalid_game_snapshot_atomically_and_clears_closed_room :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	world := ecs.init(); defer ecs.destroy(&world)
	local_entity := ecs.create_entity(&world)
	guest := Game_State{client=fixture.guest, local_peer=fixture.guest.peer_id, status=.Playing, started=time.tick_now()}
	fixture.guest = {}
	defer game_cleanup(&guest, &world)
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	test_wait_guest(&fixture, &guest, &world, 1, 0)
	version := ecs.change_version(&world)
	initial := guest.replica
	snapshot, captured := replication.snapshot_from_world(&fixture.world, fixture.host.tick+1)
	assert(captured)
	for invalid_case in 0..<3 {
		bad := snapshot
		switch invalid_case {
		case 0: bad.states[1].owner_peer = 1 // no local guest identity
		case 1: bad.states[1].position.x = ARENA_MAX.x + 1
		case 2: bad.count = 1 // host snapshots must contain both connected players
		}
		bytes: [MAX_GAME_SNAPSHOT_SIZE]u8
		size, encoded := encode_game_snapshot({snapshot = bad}, bytes[:])
		assert(encoded && network.send(&fixture.host.client, bytes[:size]))
		test_wait_guest(&fixture, &guest, &world, 1, u64(invalid_case+1))
		testing.expect(t, guest.replica == initial && ecs.change_version(&world) == version && guest.snapshots_received == 1)
	}
	network.disconnect(&fixture.host.client)
	started := time.tick_now()
	for guest.status != .Closed && time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&guest, &world, &fixture.registry)
		time.sleep(time.Millisecond)
	}
	testing.expect(t, guest.status == .Closed && guest.replica.count == 0 && !guest.replica.has_tick)
	testing.expect(t, !guest.prediction.ready && guest.prediction.pending.count == 0 && !guest.remote.initialized)
	testing.expect(t, world.entity_count == 1 && ecs.is_alive(&world, local_entity), "room closure preserves locally authored objects")
}
