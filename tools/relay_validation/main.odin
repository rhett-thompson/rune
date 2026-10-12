package main

import "core:fmt"
import "core:mem"
import "core:net"
import "core:time"
import relay "../../rune_relay/server"
import network "rune:network"

Wait_Limit :: 5*time.Second

bytes :: proc(text: string) -> []u8 {return transmute([]u8)text}

send_text :: proc(client: ^network.Client, text: string, peer: u32 = 0) {
	assert(network.send(client, bytes(text), peer))
	// send queues data; poll advances the sender's nonblocking socket too.
	packet, available, ok := network.poll(client)
	assert(ok && (!available || packet.kind == .Pong), "unexpected sender event while flushing game data")
}

// Keep the server and clients on one thread so these checks exercise the same
// nonblocking update/poll path used by a game without needing graphics.
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

expect_members :: proc(server: ^relay.Server, client: ^network.Client, peers: []u32) {
	seen: [8]bool
	assert(len(peers) <= len(seen))
	for _ in peers {
		packet := expect_packet(server, client, .Peer_Joined)
		found := false
		for peer, index in peers {
			if packet.peer == peer {
				assert(!seen[index], "existing room member was announced twice")
				seen[index], found = true, true
				break
			}
		}
		assert(found, "unexpected room member")
	}
}

expect_error :: proc(server: ^relay.Server, client: ^network.Client, code: network.Error_Code) {
	packet := expect_packet(server, client, .Error)
	assert(packet.payload_size == 1 && packet.payload[0] == u8(code), fmt.tprintf("expected relay error %v", code))
}

expect_data :: proc(server: ^relay.Server, client: ^network.Client, peer: u32, text: string) {
	packet := expect_packet(server, client, .Data)
	assert(packet.peer == peer, "relay must report the authenticated sender ID")
	assert(string(packet.payload[:packet.payload_size]) == text, "data payload changed in transit")
}

expect_quiet :: proc(server: ^relay.Server, clients: []^network.Client) {
	started := time.tick_now()
	for time.tick_since(started) < 50*time.Millisecond {
		assert(relay.server_update(server))
		for client in clients {
			packet, available, ok := network.poll(client)
			assert(ok, "quiet client unexpectedly disconnected")
			assert(!available || packet.kind == .Pong, fmt.tprintf("unexpected packet %v", packet.kind))
		}
		time.sleep(time.Millisecond)
	}
}

connect_client :: proc(server: ^relay.Server, client: ^network.Client) {
	err := network.connect(client, net.endpoint_to_string(server.endpoint))
	assert(err == nil, fmt.tprintf("connect failed: %v", err))
	assert(client.status == .Connected)
}

start_server :: proc(config: relay.Server_Config) -> relay.Server {
	server: relay.Server
	err := relay.server_start(&server, config)
	assert(err == "", err)
	assert(server.endpoint.port != 0, "ephemeral listen port was not resolved")
	return server
}

expect_connection_count :: proc(server: ^relay.Server, expected: int) {
	started := time.tick_now()
	for time.tick_since(started) < Wait_Limit {
		assert(relay.server_update(server))
		if server.stats.connections == expected {return}
		time.sleep(time.Millisecond)
	}
	assert(false, "closed peer sockets must release their server connections")
}

validate_rooms :: proc() {
	server := start_server({listen={address=net.IP4_Loopback, port=0}, max_connections=16, max_rooms=4, idle_timeout=30*time.Second, packets_per_second=256})
	defer relay.server_stop(&server)
	host, first, second, extra, other_host, other_guest: network.Client
	defer network.disconnect(&host)
	defer network.disconnect(&first)
	defer network.disconnect(&second)
	defer network.disconnect(&extra)
	defer network.disconnect(&other_host)
	defer network.disconnect(&other_guest)
	connect_client(&server, &host)
	assert(!network.send(&host, bytes("before joining")), "unjoined clients must not send game data")
	assert(network.transport_queue(&host.transport, {kind=.Data}))
	expect_error(&server, &host, .Not_In_Room)
	assert(network.create_room(&host, 3))
	expect_packet(&server, &host, .Welcome)
	assert(host.status == .In_Room && host.is_host && host.peer_id == 1)
	saved_code := host.room_code
	code := string(saved_code[:])
	assert(len(code) == 16)

	connect_client(&server, &first)
	assert(network.join_room(&first, code))
	expect_packet(&server, &first, .Joined)
	expect_members(&server, &first, {1})
	joined := expect_packet(&server, &host, .Peer_Joined)
	assert(first.status == .In_Room && !first.is_host && first.peer_id > 1)
	assert(joined.peer == first.peer_id && first.room_code == host.room_code)

	connect_client(&server, &second)
	assert(network.join_room(&second, code))
	expect_packet(&server, &second, .Joined)
	expect_members(&server, &second, {1, first.peer_id})
	joined = expect_packet(&server, &host, .Peer_Joined)
	assert(joined.peer == second.peer_id && second.peer_id != first.peer_id)
	joined = expect_packet(&server, &first, .Peer_Joined)
	assert(joined.peer == second.peer_id)

	// Inputs go only to the host; authoritative state goes from the host to
	// all guests or one selected guest, with sender identities set by the relay.
	assert(!network.send(&first, bytes("guest broadcast")))
	send_text(&first, "input:first", 1)
	expect_data(&server, &host, first.peer_id, "input:first")
	expect_quiet(&server, {&first, &second})
	send_text(&second, "input:second", 1)
	expect_data(&server, &host, second.peer_id, "input:second")
	send_text(&host, "state:all")
	expect_data(&server, &first, 1, "state:all")
	expect_data(&server, &second, 1, "state:all")
	expect_quiet(&server, {&host})
	send_text(&host, "state:first", first.peer_id)
	expect_data(&server, &first, 1, "state:first")
	expect_quiet(&server, {&host, &second})
	binary: [network.MAX_PAYLOAD]u8
	for &value, index in binary {value = u8(index % 256)}
	send_text(&host, string(binary[:]), first.peer_id)
	data := expect_packet(&server, &first, .Data)
	assert(data.peer == 1 && data.payload_size == len(binary) && data.payload == binary, "maximum-size binary payload changed in transit")
	assert(!network.send(&first, bytes("forged guest state"), second.peer_id), "guest-to-guest game data must be rejected")
	// Bypass the client convenience checks: the server must enforce authority
	// against an independently written or deliberately modified client too.
	assert(network.transport_queue(&first.transport, {kind=.Data, peer=second.peer_id}))
	expect_error(&server, &first, .Forbidden)
	expect_quiet(&server, {&host, &second})
	oversized: [1025]u8
	assert(!network.send(&host, oversized[:]), "oversized messages must be rejected")

	connect_client(&server, &extra)
	assert(!network.join_room(&extra, "bad-code"), "malformed room codes must be rejected")
	assert(network.join_room(&extra, "0000000000000000"))
	expect_error(&server, &extra, .Room_Not_Found)
	assert(extra.status == .Connected)
	assert(network.join_room(&extra, code))
	expect_error(&server, &extra, .Room_Full)
	assert(extra.status == .Connected)

	connect_client(&server, &other_host)
	assert(network.create_room(&other_host, 2))
	expect_packet(&server, &other_host, .Welcome)
	assert(other_host.room_code != host.room_code)
	connect_client(&server, &other_guest)
	assert(network.join_room(&other_guest, string(other_host.room_code[:])))
	expect_packet(&server, &other_guest, .Joined)
	expect_members(&server, &other_guest, {1})
	expect_packet(&server, &other_host, .Peer_Joined)
	send_text(&host, "main room only")
	expect_data(&server, &first, 1, "main room only")
	expect_data(&server, &second, 1, "main room only")
	expect_quiet(&server, {&other_host, &other_guest, &extra})
	send_text(&other_guest, "other input", 1)
	expect_data(&server, &other_host, other_guest.peer_id, "other input")
	expect_quiet(&server, {&host, &first, &second})

	departed := first.peer_id
	network.disconnect(&first)
	left := expect_packet(&server, &host, .Peer_Left)
	assert(left.peer == departed)
	left = expect_packet(&server, &second, .Peer_Left)
	assert(left.peer == departed)
	assert(network.join_room(&extra, code), "departing guests must release their room slot")
	expect_packet(&server, &extra, .Joined)
	expect_members(&server, &extra, {1, second.peer_id})
	assert(extra.peer_id != departed, "peer IDs must not be reused within a room")
	joined = expect_packet(&server, &host, .Peer_Joined)
	assert(joined.peer == extra.peer_id)
	joined = expect_packet(&server, &second, .Peer_Joined)
	assert(joined.peer == extra.peer_id)

	network.disconnect(&host)
	expect_packet(&server, &second, .Room_Closed)
	expect_packet(&server, &extra, .Room_Closed)
	assert(second.status == .Disconnected && extra.status == .Disconnected)
	assert(!second.is_host && second.peer_id == 0)
	connect_client(&server, &second)
	assert(network.join_room(&second, code))
	expect_error(&server, &second, .Room_Not_Found)
	expect_quiet(&server, {&other_host, &other_guest})
	assert(network.create_room(&second, 2), "clients must be able to reconnect and create a new room")
	expect_packet(&server, &second, .Welcome)
	assert(second.is_host && second.peer_id == 1 && second.room_code != saved_code)
}

raw_connect :: proc(server: ^relay.Server) -> net.TCP_Socket {
	socket, err := net.dial_tcp(server.endpoint)
	assert(err == nil)
	assert(net.set_blocking(socket, false) == nil)
	assert(relay.server_update(server))
	return socket
}

raw_send :: proc(socket: net.TCP_Socket, buffer: []u8) {
	written, err := net.send_tcp(socket, buffer)
	assert(err == nil && written == len(buffer), "small loopback write failed")
}

// This decoder deliberately uses raw core:net sockets, independent of Client,
// so malformed framing and a fatal response followed by EOF are both tested.
raw_expect_rejection :: proc(server: ^relay.Server, socket: net.TCP_Socket) {
	buffer: [network.MAX_FRAME*2]u8
	count := 0
	rejected := false
	started := time.tick_now()
	for time.tick_since(started) < Wait_Limit {
		assert(relay.server_update(server))
		read, err := net.recv_tcp(socket, buffer[count:])
		if err == .Would_Block || err == .Interrupted {
			time.sleep(time.Millisecond)
			continue
		}
		if err != nil || read == 0 {
			assert(rejected, "server closed malformed client without a protocol error")
			return
		}
		count += read
		for {
			packet, consumed, valid := network.frame_decode(buffer[:count])
			assert(valid, "relay sent malformed framing")
			if consumed == 0 {break}
			assert(!rejected && packet.kind == .Error && packet.payload_size == 1 && packet.payload[0] == u8(network.Error_Code.Invalid_Request))
			rejected = true
			copy(buffer[:count-consumed], buffer[consumed:count])
			count -= consumed
		}
	}
	assert(false, "malformed or rate-limited client did not close")
}

validate_bad_frames :: proc() {
	server := start_server({listen={address=net.IP4_Loopback, port=0}, max_connections=2, max_rooms=1, idle_timeout=30*time.Second, packets_per_second=256})
	defer relay.server_stop(&server)
	for malformed in 0..<6 {
		socket := raw_connect(&server)
		frame: [network.MAX_FRAME]u8
		size, valid := network.frame_encode({kind=.Ping}, frame[:])
		assert(valid)
		switch malformed {
		case 0: frame[0], frame[1], size = 0, 0, 2
		case 1: frame[0], frame[1], size = 0xff, 0xff, 2
		case 2: frame[2] = 'X'
		case 3: frame[6] = network.PROTOCOL_VERSION+1
		case 4: frame[7] = 0xff
		case 5: frame[7] = u8(network.Kind.Welcome)
		}
		raw_send(socket, frame[:size])
		raw_expect_rejection(&server, socket)
		net.close(socket)
	}
	expect_connection_count(&server, 0)
	assert(server.stats.connections == 0 && server.stats.rooms == 0)
}

validate_rate_limit :: proc() {
	server := start_server({listen={address=net.IP4_Loopback, port=0}, max_connections=2, max_rooms=1, idle_timeout=30*time.Second, packets_per_second=2})
	defer relay.server_stop(&server)
	socket := raw_connect(&server)
	socket_open := true
	defer if socket_open {net.close(socket)}
	frame: [network.MAX_FRAME]u8
	// Use structurally valid Create requests with an invalid capacity. The
	// first two requests produce ordinary errors; the third trips the rate cap.
	request := network.Packet{kind=.Create, payload_size=1}
	request.payload[0] = 1
	size, encoded := network.frame_encode(request, frame[:])
	assert(encoded)
	burst: [network.MAX_FRAME*3]u8
	for index in 0..<3 {copy(burst[index*size:(index+1)*size], frame[:size])}
	raw_send(socket, burst[:3*size])
	buffer: [network.MAX_FRAME*2]u8
	count, errors := 0, 0
	started := time.tick_now()
	for time.tick_since(started) < Wait_Limit {
		assert(relay.server_update(&server))
		read, err := net.recv_tcp(socket, buffer[count:])
		if err == .Would_Block || err == .Interrupted {time.sleep(time.Millisecond); continue}
		if err != nil || read == 0 {
			assert(errors == 3, "rate limit did not close the client after reporting each rejection")
			// A graceful server close can retain the receive half until this raw
			// peer closes too. Require the connection slot to be reclaimed after.
			net.close(socket)
			socket_open = false
			expect_connection_count(&server, 0)
			return
		}
		count += read
		for {
			packet, consumed, valid := network.frame_decode(buffer[:count])
			assert(valid)
			if consumed == 0 {break}
			assert(packet.kind == .Error && packet.payload_size == 1 && packet.payload[0] == u8(network.Error_Code.Invalid_Request))
			errors += 1
			copy(buffer[:count-consumed], buffer[consumed:count])
			count -= consumed
		}
	}
	assert(false, "rate-limited client did not close")
}

validate_stream_frames :: proc() {
	server := start_server({listen={address=net.IP4_Loopback, port=0}, max_connections=2, max_rooms=1, idle_timeout=30*time.Second, packets_per_second=256})
	defer relay.server_stop(&server)
	client: network.Client
	defer network.disconnect(&client)
	connect_client(&server, &client)
	frame: [network.MAX_FRAME]u8
	size, valid := network.frame_encode({kind=.Ping}, frame[:])
	assert(valid)
	raw_send(client.transport.socket, frame[:1])
	expect_quiet(&server, {&client})
	raw_send(client.transport.socket, frame[1:5])
	expect_quiet(&server, {&client})
	raw_send(client.transport.socket, frame[5:size])
	expect_packet(&server, &client, .Pong)
	coalesced: [network.MAX_FRAME*3]u8
	for index in 0..<3 {copy(coalesced[index*size:(index+1)*size], frame[:size])}
	raw_send(client.transport.socket, coalesced[:3*size])
	for _ in 0..<3 {expect_packet(&server, &client, .Pong)}
	expect_quiet(&server, {&client})
}

validate_connection_limit :: proc() {
	server := start_server({listen={address=net.IP4_Loopback, port=0}, max_connections=1, max_rooms=1, idle_timeout=30*time.Second, packets_per_second=256})
	defer relay.server_stop(&server)
	first, extra: network.Client
	defer network.disconnect(&first)
	defer network.disconnect(&extra)
	connect_client(&server, &first)
	assert(relay.server_update(&server) && server.stats.connections == 1)
	connect_client(&server, &extra)
	started := time.tick_now()
	closed := false
	for time.tick_since(started) < Wait_Limit {
		assert(relay.server_update(&server))
		_, _, ok := network.poll(&extra)
		if !ok {closed = true; break}
		time.sleep(time.Millisecond)
	}
	assert(closed && server.stats.connections == 1, "connections above the server limit must close")
	network.disconnect(&first)
	started = time.tick_now()
	for server.stats.connections != 0 && time.tick_since(started) < Wait_Limit {
		assert(relay.server_update(&server))
		time.sleep(time.Millisecond)
	}
	assert(server.stats.connections == 0)
	connect_client(&server, &extra)
	assert(network.create_room(&extra, 2))
	expect_packet(&server, &extra, .Welcome)
	assert(server.stats.connections == 1 && server.stats.rooms == 1, "closed connections must release their server slot")
}

validate_room_limit :: proc() {
	server := start_server({listen={address=net.IP4_Loopback, port=0}, max_connections=4, max_rooms=1, idle_timeout=30*time.Second, packets_per_second=256})
	defer relay.server_stop(&server)
	first, second: network.Client
	defer network.disconnect(&first)
	defer network.disconnect(&second)
	connect_client(&server, &first)
	connect_client(&server, &second)
	assert(network.create_room(&first, 2))
	expect_packet(&server, &first, .Welcome)
	assert(network.create_room(&second, 2))
	expect_error(&server, &second, .Server_Full)
	network.disconnect(&first)
	assert(network.create_room(&second, 2))
	expect_packet(&server, &second, .Welcome)
}

validate_idle_timeout :: proc() {
	server := start_server({listen={address=net.IP4_Loopback, port=0}, max_connections=2, max_rooms=1, idle_timeout=150*time.Millisecond, packets_per_second=256})
	defer relay.server_stop(&server)
	client: network.Client
	defer network.disconnect(&client)
	connect_client(&server, &client)
	started := time.tick_now()
	for time.tick_since(started) < Wait_Limit {
		assert(relay.server_update(&server))
		_, _, ok := network.poll(&client)
		if !ok {
			assert(client.status == .Disconnected)
			return
		}
		time.sleep(time.Millisecond)
	}
	assert(false, "idle clients must expire within the configured timeout")
}

main :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_rooms()
	validate_room_limit()
	validate_idle_timeout()
	validate_connection_limit()
	validate_stream_frames()
	validate_bad_frames()
	validate_rate_limit()
	assert(len(tracker.bad_free_array) == 0 && tracker.current_memory_allocated == 0 && len(tracker.allocation_map) == 0, "relay allocations must be released")
	fmt.println("PASS relay room creation/join, authenticated routing, host authority, broadcast/target, isolation, room/connection capacity, departure, host teardown, slot reuse, idle timeout, fragmented/coalesced frames, malformed framing, rate limits, allocation cleanup")
}
