package server

import "core:mem"
import "core:net"
import "core:testing"
import "core:time"
import "rune:network"

@(test)
relay_start_configuration_and_allocation_lifetime :: proc(t: ^testing.T) {
	server: Server
	testing.expect(t, server_start(&server, {max_connections = -1}) != "")
	testing.expect(t, server_start(&server, {max_connections = 1, max_rooms = 2}) != "")
	testing.expect(t, !server.running)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	previous := context.allocator
	context.allocator = mem.tracking_allocator(&tracker)
	for _ in 0..<2 {
		error := server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2})
		testing.expect_value(t, error, "")
		testing.expect(t, server.running && server.endpoint.port > 0)
		testing.expect(t, server_start(&server, {}) != "")
		server_stop(&server)
		server_stop(&server)
		testing.expect(t, !server.running)
	}
	context.allocator = previous
	testing.expect_value(t, tracker.current_memory_allocated, 0)
	testing.expect_value(t, len(tracker.bad_free_array), 0)
}

@(test)
relay_forwards_both_directions_in_one_update_for_either_connection_order :: proc(t: ^testing.T) {
	for host_first in ([2]bool{true, false}) {
		server: Server
		assert(server_start(&server, {listen = {net.IP4_Loopback, 0}, max_connections = 2, max_rooms = 1}) == "")
		defer server_stop(&server)
		clients: [2]network.Client
		defer {for &client in clients {network.disconnect(&client)}}
		for &client in clients {assert(network.connect(&client, net.endpoint_to_string(server.endpoint)) == nil)}
		assert(server_update(&server) && server.stats.connections == 2)
		// Supply room membership directly: this regression concerns forwarding
		// order, and uses actual client/relay TCP connections for delivery.
		server.rooms[0] = {active = true, capacity = 2, members = 2, next_peer = 3}
		server.stats.rooms = 1
		for &client, index in clients {
			peer := u32(1) if (index == 0) == host_first else u32(2)
			client.status, client.peer_id, client.is_host = .In_Room, peer, peer == 1
			server.connections[index].room, server.connections[index].peer = 0, peer
		}
		for sender_index in 0..<2 {
			receiver_index := 1 - sender_index
			sender := &server.connections[sender_index]
			receiver := &clients[receiver_index]
			packet := network.Packet{kind = .Data, peer = receiver.peer_id, payload_size = 1}
			packet.payload[0] = u8(sender_index+1)
			// A complete frame is already received before the sole update under
			// test, avoiding TCP arrival timing races without running a second pump.
			size, encoded := network.frame_encode(packet, sender.transport.recv_buffer[:])
			assert(encoded && sender.transport.recv_count == 0)
			sender.transport.recv_count = size
			assert(server_update(&server))
			testing.expect(t, server.connections[receiver_index].transport.send_count == 0,
				"the same relay update must flush forwarding to an already visited connection")
			started := time.tick_now()
			delivered := false
			for time.tick_since(started) < time.Second {
				value, available, ok := network.poll(receiver)
				assert(ok)
				if available {
					delivered = value.kind == .Data && value.peer == sender.peer && value.payload_size == 1 && value.payload[0] == packet.payload[0]
					break
				}
				time.sleep(time.Millisecond)
			}
			testing.expect(t, delivered, "both forwarding directions must arrive without a second server_update")
		}
		testing.expect(t, server.stats.forwarded == 2 && server.stats.rejected == 0 && server.stats.disconnected == 0)
	}
}
