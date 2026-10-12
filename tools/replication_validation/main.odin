package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:time"
import relay "../../rune_relay/server"
import "rune:ecs"
import "rune:network"
import "rune:replication"

Wait_Limit :: 5*time.Second

// Exercise the production TCP relay and client poll path on one thread. Every
// wait is bounded, and this executable never creates a renderer or window.
expect_packet :: proc(server: ^relay.Server, client: ^network.Client, kind: network.Kind) -> network.Packet {
	started := time.tick_now()
	for time.tick_since(started) < Wait_Limit {
		assert(relay.server_update(server), "relay update failed")
		packet, available, ok := network.poll(client)
		assert(ok, fmt.tprintf("client disconnected while waiting for %v", kind))
		if available {
			if packet.kind == .Pong && kind != .Pong {continue}
			assert(packet.kind == kind, fmt.tprintf("expected %v, received %v", kind, packet.kind))
			return packet
		}
		time.sleep(time.Millisecond)
	}
	assert(false, fmt.tprintf("timed out waiting for %v", kind))
	return {}
}

expect_quiet :: proc(server: ^relay.Server, clients: []^network.Client) {
	started := time.tick_now()
	for time.tick_since(started) < 50*time.Millisecond {
		assert(relay.server_update(server))
		for client in clients {
			packet, available, ok := network.poll(client)
			assert(ok && (!available || packet.kind == .Pong), "unauthorized game data reached a guest")
		}
		time.sleep(time.Millisecond)
	}
}

flush :: proc(client: ^network.Client) {
	packet, available, ok := network.poll(client)
	assert(ok && (!available || packet.kind == .Pong), "unexpected event while flushing game data")
}

connect :: proc(server: ^relay.Server, client: ^network.Client) {
	assert(network.connect(client, net.endpoint_to_string(server.endpoint)) == nil)
}

join :: proc(server: ^relay.Server, host, guest: ^network.Client) -> u32 {
	connect(server, guest)
	assert(network.join_room(guest, string(host.room_code[:])))
	expect_packet(server, guest, .Joined)
	// The relay announces every currently connected member to the new peer.
	for _ in 0..<server.rooms[0].members-1 {expect_packet(server, guest, .Peer_Joined)}
	joined := expect_packet(server, host, .Peer_Joined)
	assert(joined.peer == guest.peer_id && guest.peer_id != 1)
	return guest.peer_id
}

spawn :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, id, peer: u32, position: [2]f32) -> ecs.Entity {
	entity := ecs.create_entity(world)
	assert(entity != 0)
	assert(ecs.add(world, registry, entity, replication.Identity{id=id, owner_peer=peer}))
	assert(ecs.add(world, registry, entity, ecs.Transform{position={position.x, position.y, 0}, scale={1,1,1}}))
	return entity
}

send_snapshot :: proc(host: ^network.Client, world: ^ecs.World, tick: u32, peer: u32 = 0) -> replication.Snapshot {
	snapshot, captured := replication.snapshot_from_world(world, tick)
	assert(captured)
	buffer: [network.MAX_PAYLOAD]u8
	size, encoded := replication.encode_snapshot(snapshot, buffer[:])
	assert(encoded && network.send(host, buffer[:size], peer))
	flush(host)
	return snapshot
}

receive_snapshot :: proc(server: ^relay.Server, client: ^network.Client, replica: ^replication.Replica, world: ^ecs.World, registry: ^ecs.Component_Registry, should_apply := true) -> replication.Snapshot {
	packet := expect_packet(server, client, .Data)
	assert(packet.peer == 1, "only the authenticated host supplies snapshots")
	snapshot, decoded := replication.decode_snapshot(packet.payload[:packet.payload_size])
	assert(decoded && replication.apply_snapshot(replica, world, registry, snapshot) == should_apply)
	return snapshot
}

assert_matches :: proc(host_world, guest_world: ^ecs.World, replica: ^replication.Replica, snapshot: replication.Snapshot) {
	assert(replica.count == snapshot.count)
	for index in 0..<snapshot.count {
		state := snapshot.states[index]
		guest_entity, found := replication.entity_for_id(replica, state.id)
		assert(found && ecs.is_alive(guest_world, guest_entity))
		identity, identified := ecs.get(guest_world, guest_entity, replication.Identity)
		transform, transformed := ecs.get_transform(guest_world, guest_entity)
		assert(identified && identity.id == state.id && identity.owner_peer == state.owner_peer)
		assert(transformed && transform.position == [3]f32{state.position.x, state.position.y, 0})
		host_found := false
		for host_entity in host_world.entities {
			host_identity, has_identity := ecs.get(host_world, host_entity, replication.Identity)
			if !has_identity || host_identity.id != state.id {continue}
			host_transform, _ := ecs.get_transform(host_world, host_entity)
			assert(host_entity != guest_entity, "network IDs must not be Rune entity handles")
			assert(host_identity == identity && host_transform.position == transform.position)
			host_found = true
			break
		}
		assert(host_found)
	}
}

validate_replication :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry) && replication.register(&registry))
	host_world := ecs.init(); defer ecs.destroy(&host_world)
	guest_world := ecs.init(); defer ecs.destroy(&guest_world)
	// Local authored objects must survive both snapshot reconciliation and clear.
	host_local := ecs.create_entity(&host_world)
	guest_local := ecs.create_entity(&guest_world)
	assert(host_local != guest_local)
	replica: replication.Replica
	defer replication.clear(&replica, &guest_world)

	server: relay.Server
	assert(relay.server_start(&server, {listen={address=net.IP4_Loopback, port=0}, max_connections=8, max_rooms=1}) == "")
	defer relay.server_stop(&server)
	host, guest, second: network.Client
	defer network.disconnect(&host)
	defer network.disconnect(&guest)
	defer network.disconnect(&second)
	connect(&server, &host)
	assert(network.create_room(&host, 8))
	expect_packet(&server, &host, .Welcome)
	assert(host.peer_id == 1)
	guest_peer := join(&server, &host, &guest)
	second_peer := join(&server, &host, &second)
	joined := expect_packet(&server, &guest, .Peer_Joined)
	assert(joined.peer == second_peer)
	host_player := spawn(&host_world, &registry, 100, host.peer_id, {0, 0})
	guest_player := spawn(&host_world, &registry, 101, guest_peer, {40, 60})
	second_player := spawn(&host_world, &registry, 102, second_peer, {-40, 60})
	initial := send_snapshot(&host, &host_world, 1)
	received := receive_snapshot(&server, &guest, &replica, &guest_world, &registry)
	assert(received.count == 3 && received.tick == initial.tick)
	assert_matches(&host_world, &guest_world, &replica, received)
	expect_packet(&server, &second, .Data)
	guest_handle, _ := replication.entity_for_id(&replica, 101)
	second_handle, _ := replication.entity_for_id(&replica, 102)

	// Input contains axes and sequence only: the peer identity comes from relay.
	buffer: [network.MAX_PAYLOAD]u8
	size, encoded := replication.encode_input({sequence=1, axis={1,-1}}, buffer[:])
	assert(encoded && network.send(&guest, buffer[:size], 1)); flush(&guest)
	input_packet := expect_packet(&server, &host, .Data)
	assert(input_packet.peer == guest_peer)
	command, decoded := replication.decode_input(input_packet.payload[:input_packet.payload_size])
	assert(decoded && command.axis == [2]i8{1,-1} && command.sequence == 1)
	before, _ := ecs.get_transform(&host_world, guest_player)
	// One authoritative fixed step, with bounded axes and fixed speed/duration.
	after := before
	after.position.x += f32(command.axis.x)*120*(1.0/60.0)
	after.position.y += f32(command.axis.y)*120*(1.0/60.0)
	assert(ecs.set_transform(&host_world, guest_player, after))
	assert(after.position == [3]f32{42,58,0})
	host_position, _ := ecs.get_transform(&host_world, host_player)
	assert(host_position.position == [3]f32{})
	updated := send_snapshot(&host, &host_world, 2)
	received = receive_snapshot(&server, &guest, &replica, &guest_world, &registry)
	expect_packet(&server, &second, .Data)
	assert_matches(&host_world, &guest_world, &replica, received)
	same_handle, _ := replication.entity_for_id(&replica, 101)
	assert(same_handle == guest_handle, "updates must retain each local entity handle")

	// Rejected application payloads and stale snapshots must be atomic.
	version := ecs.change_version(&guest_world)
	bad := updated
	bad.tick = 3
	bad.states[1].id = bad.states[0].id
	assert(!replication.apply_snapshot(&replica, &guest_world, &registry, bad))
	assert(ecs.change_version(&guest_world) == version && replica.last_tick == 2)
	assert_matches(&host_world, &guest_world, &replica, updated)
	size, encoded = replication.encode_snapshot(initial, buffer[:])
	assert(encoded && network.send(&host, buffer[:size], guest_peer)); flush(&host)
	received = receive_snapshot(&server, &guest, &replica, &guest_world, &registry, should_apply = false)
	assert(received.tick == initial.tick, "old snapshots should be ignored")
	assert(replica.last_tick == 2 && ecs.change_version(&guest_world) == version)
	assert_matches(&host_world, &guest_world, &replica, updated)
	size, encoded = replication.encode_snapshot(updated, buffer[:])
	assert(encoded)
	assert(network.send(&host, buffer[:size-1], guest_peer)); flush(&host)
	malformed := expect_packet(&server, &guest, .Data)
	_, decoded = replication.decode_snapshot(malformed.payload[:malformed.payload_size])
	assert(!decoded && ecs.change_version(&guest_world) == version)
	// A guest sending a valid snapshot to host still cannot supply player input.
	assert(network.send(&second, buffer[:size], 1)); flush(&second)
	forged := expect_packet(&server, &host, .Data)
	assert(forged.peer == second_peer)
	_, decoded = replication.decode_input(forged.payload[:forged.payload_size])
	assert(!decoded)
	unchanged, _ := ecs.get_transform(&host_world, guest_player)
	assert(unchanged.position == after.position)
	// Bypass client convenience checks to exercise server-side guest isolation.
	forged.peer = guest_peer
	assert(network.transport_queue(&second.transport, forged))
	flush(&second)
	rejected := expect_packet(&server, &second, .Error)
	assert(rejected.payload_size == 1 && rejected.payload[0] == u8(network.Error_Code.Forbidden))
	expect_quiet(&server, {&guest, &host})

	// Guest departure despawns just its owned entity in the host and next snapshot.
	network.disconnect(&second)
	left := expect_packet(&server, &host, .Peer_Left)
	assert(left.peer == second_peer)
	assert(ecs.destroy_entity(&host_world, second_player))
	left = expect_packet(&server, &guest, .Peer_Left)
	assert(left.peer == second_peer)
	send_snapshot(&host, &host_world, 3)
	received = receive_snapshot(&server, &guest, &replica, &guest_world, &registry)
	assert(received.count == 2 && !ecs.is_alive(&guest_world, second_handle))
	_, found := replication.entity_for_id(&replica, 102)
	assert(!found && ecs.is_alive(&guest_world, guest_handle))
	assert_matches(&host_world, &guest_world, &replica, received)

	// Rejoining gets fresh peer/network IDs; surviving player identities persist.
	rejoined_peer := join(&server, &host, &second)
	assert(rejoined_peer != second_peer)
	joined = expect_packet(&server, &guest, .Peer_Joined)
	assert(joined.peer == rejoined_peer)
	spawn(&host_world, &registry, 103, rejoined_peer, {-40,60})
	send_snapshot(&host, &host_world, 4)
	received = receive_snapshot(&server, &guest, &replica, &guest_world, &registry)
	expect_packet(&server, &second, .Data)
	new_handle: ecs.Entity
	new_handle, found = replication.entity_for_id(&replica, 103)
	assert(found && new_handle != second_handle && !ecs.is_alive(&guest_world, second_handle))
	same_handle, found = replication.entity_for_id(&replica, 101)
	assert(found && same_handle == guest_handle)
	assert_matches(&host_world, &guest_world, &replica, received)

	network.disconnect(&host)
	expect_packet(&server, &guest, .Room_Closed)
	expect_packet(&server, &second, .Room_Closed)
	assert(guest.status == .Disconnected && second.status == .Disconnected)
	replication.clear(&replica, &guest_world)
	assert(replica.count == 0 && !replica.has_tick)
	assert(!ecs.is_alive(&guest_world, guest_handle) && !ecs.is_alive(&guest_world, new_handle))
	assert(ecs.is_alive(&guest_world, guest_local) && guest_world.entity_count == 1)
	assert(ecs.is_alive(&host_world, host_local))
}

main :: proc() {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_replication()
	assert(len(tracker.bad_free_array) == 0)
	assert(tracker.current_memory_allocated == 0 && len(tracker.allocation_map) == 0, "replication and relay allocations must be released")
	fmt.println("PASS real relay input/state, independent ECS handles, stable IDs, stale/malformed atomic rejection, guest isolation, despawn/rejoin/room cleanup, complete allocation cleanup")
}
