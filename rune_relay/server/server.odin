// Package server provides the standalone, renderer-independent room relay.
// The host owns simulation; the relay only authenticates and forwards messages.
package server

import "core:crypto"
import "core:mem"
import "core:net"
import "core:time"
import "rune:network"

Server_Config :: struct {
	listen:             net.Endpoint,
	max_connections:    int,
	max_rooms:          int,
	idle_timeout:       time.Duration,
	packets_per_second: int,
	udp_enabled:        bool,
	udp_configured:     bool, // False selects enabled UDP for zero-value configurations.
}

Server_Stats :: struct {
	connections, rooms:                           int,
	accepted, forwarded, rejected, disconnected: u64,
	udp_received, udp_forwarded, udp_rejected, udp_dropped: u64,
}

Server :: struct {
	endpoint:    net.Endpoint,
	stats:       Server_Stats,
	config:      Server_Config,
	listener:    net.TCP_Socket,
	udp_socket:  net.UDP_Socket,
	udp_open:    bool,
	udp_sessions: map[[network.UDP_TOKEN_SIZE]u8]int,
	running:     bool,
	connections: []Server_Connection,
	rooms:       []Server_Room,
	allocator:   mem.Allocator,
}

Server_Connection :: struct {
	transport:                       network.Transport,
	room:                            int,
	peer:                            u32,
	last_activity, rate_start, close_started: time.Tick,
	packet_count:                    int,
	failed, closing, write_shutdown: bool,
	tcp_address:                     net.Address,
	udp_token:                       [network.UDP_TOKEN_SIZE]u8,
	udp_issued, udp_bound:            bool,
	udp_endpoint:                    net.Endpoint,
	udp_send_sequence:               u32,
	udp_bind_sequence:               u32,
	udp_replay:                      network.Replay_Window,
}

Server_Room :: struct {
	active:                   bool,
	code:                     [network.CODE_SIZE]u8,
	capacity, members:        int,
	next_peer:                u32,
}

// Zero configuration values select conservative defaults. Port zero lets the
// OS select a free port, useful for local integration tests.
server_start :: proc(server: ^Server, config: Server_Config) -> string {
	if server.running {return "relay is already running"}
	cfg := config
	if cfg.listen.address == nil {cfg.listen = {net.IP4_Loopback, 7777}}
	if cfg.max_connections == 0 {cfg.max_connections = 128}
	if cfg.max_rooms == 0 {cfg.max_rooms = min(64, cfg.max_connections)}
	if cfg.idle_timeout == 0 {cfg.idle_timeout = 30 * time.Second}
	if cfg.packets_per_second == 0 {cfg.packets_per_second = 256}
	if !cfg.udp_configured {cfg.udp_enabled = true}
	if cfg.listen.port < 0 || cfg.listen.port > 65535 {return "invalid listen port"}
	if cfg.max_connections < 1 || cfg.max_connections > 4096 {return "max_connections must be 1..4096"}
	if cfg.max_rooms < 1 || cfg.max_rooms > cfg.max_connections {return "max_rooms must be 1..max_connections"}
	if cfg.idle_timeout <= 0 || cfg.packets_per_second < 1 {return "timeout and packet limit must be positive"}
	connections, allocation_error := make([]Server_Connection, cfg.max_connections)
	if allocation_error != nil {return "unable to allocate relay connections"}
	rooms, room_error := make([]Server_Room, cfg.max_rooms)
	if room_error != nil {delete(connections); return "unable to allocate relay rooms"}
	listener, listen_error := net.listen_tcp(cfg.listen, min(cfg.max_connections, 128))
	if listen_error != nil {delete(connections); delete(rooms); return "unable to listen on relay endpoint"}
	if net.set_blocking(listener, false) != nil {
		net.close(listener); delete(connections); delete(rooms)
		return "unable to make relay listener nonblocking"
	}
	endpoint, endpoint_error := net.bound_endpoint(listener)
	if endpoint_error != nil {
		net.close(listener); delete(connections); delete(rooms)
		return "unable to inspect relay endpoint"
	}
	udp_socket: net.UDP_Socket
	udp_sessions: map[[network.UDP_TOKEN_SIZE]u8]int
	if cfg.udp_enabled {
		// The TCP listener resolves port zero first. Both transports must then
		// advertise and bind the same actual endpoint, including IPv6 listeners.
		udp_error: net.Network_Error
		udp_socket, udp_error = net.make_unbound_udp_socket(net.family_from_endpoint(endpoint))
		if udp_error != nil {
			net.close(listener); delete(connections); delete(rooms)
			return "unable to create relay UDP socket"
		}
		if net.bind(udp_socket, endpoint) != nil || net.set_blocking(udp_socket, false) != nil {
			net.close(udp_socket); net.close(listener); delete(connections); delete(rooms)
			return "unable to bind nonblocking relay UDP endpoint"
		}
		allocation_error: mem.Allocator_Error
		udp_sessions, allocation_error = make(map[[network.UDP_TOKEN_SIZE]u8]int, cfg.max_connections)
		if allocation_error != nil {
			net.close(udp_socket); net.close(listener); delete(connections); delete(rooms)
			return "unable to allocate relay UDP sessions"
		}
	}
	server^ = {endpoint = endpoint, config = cfg, listener = listener, running = true,
		udp_socket = udp_socket, udp_open = cfg.udp_enabled, udp_sessions = udp_sessions,
		connections = connections, rooms = rooms, allocator = context.allocator}
	return ""
}

server_stop :: proc(server: ^Server) {
	if !server.running {return}
	for &connection in server.connections {network.transport_close(&connection.transport)}
	net.close(server.listener)
	if server.udp_open {net.close(server.udp_socket)}
	delete(server.udp_sessions)
	server.udp_sessions = nil
	server.udp_open = false
	server.udp_socket = {}
	delete(server.connections, server.allocator)
	delete(server.rooms, server.allocator)
	server.connections = nil
	server.rooms = nil
	server.running = false
	server.stats.connections = 0
	server.stats.rooms = 0
}

// Each call accepts at most 16 connections and processes at most 32 frames per
// connection. Fixed buffers and quotas bound work even for malicious clients.
// All server/client procedures must run on their owning thread.
server_update :: proc(server: ^Server) -> bool {
	if !server.running {return false}
	now := time.tick_now()
	for _ in 0..<16 {
		socket, remote, err := net.accept_tcp(server.listener)
		if err == .Would_Block || err == .Interrupted || err == .Aborted {break}
		if err != nil {return false}
		free := -1
		for &connection, index in server.connections {
			if !connection.transport.open {free = index; break}
		}
		if free < 0 {
			net.close(socket)
			server.stats.rejected += 1
			continue
		}
		connection := &server.connections[free]
		connection^ = {room = -1, last_activity = now, rate_start = now, tcp_address = remote.address}
		if !network.transport_init(&connection.transport, socket) {continue}
		server.stats.connections += 1
		server.stats.accepted += 1
	}
	for &connection, index in server.connections {
		if !connection.transport.open {continue}
		if connection.failed || !network.transport_flush(&connection.transport) {
			server_disconnect(server, index)
			continue
		}
		if connection.closing {
			// Closing a TCP socket with unread guest input can reset the connection
			// and erase its final Room_Closed/Error event. Send FIN after flushing,
			// then drain input until the peer closes or the bounded grace expires.
			if connection.transport.send_count == 0 && !connection.write_shutdown {
				if net.shutdown(connection.transport.socket, .Send) != nil {
					server_disconnect(server, index)
					continue
				}
				connection.write_shutdown = true
			}
			read, receive_error := net.recv_tcp(connection.transport.socket, connection.transport.recv_buffer[:])
			if receive_error != nil && receive_error != .Would_Block && receive_error != .Interrupted {
				server_disconnect(server, index)
				continue
			}
			if (read == 0 && receive_error == nil) || time.tick_diff(connection.close_started, now) > time.Second {
				server_disconnect(server, index)
			}
			continue
		}
		if time.tick_diff(connection.last_activity, now) >= server.config.idle_timeout {
			server_disconnect(server, index)
			continue
		}
		if !network.transport_receive(&connection.transport) {
			server_disconnect(server, index)
			continue
		}
		for _ in 0..<32 {
			packet, available, valid := network.transport_next(&connection.transport)
			if !valid {server_error(server, index, .Invalid_Request, true); break}
			if !available {break}
			if !server_rate_accept(server, index, now) {break}
			server_handle(server, index, packet)
			if !connection.transport.open || connection.failed || connection.closing {break}
		}
		if connection.transport.open && (connection.failed || !network.transport_flush(&connection.transport)) {
			server_disconnect(server, index)
		}
	}
	if server.udp_open && !server_udp_update(server, now) {return false}
	// A later connection can forward into an earlier connection after that
	// connection's visit. Flush those replies before the caller sleeps, so
	// delivery does not depend on the order clients connected.
	for &connection, index in server.connections {
		if connection.transport.open && (connection.failed || !network.transport_flush(&connection.transport)) {
			server_disconnect(server, index)
		}
	}
	return true
}

@(private)
server_queue :: proc(server: ^Server, index: int, packet: network.Packet) -> bool {
	connection := &server.connections[index]
	if connection.failed || !connection.transport.open {return false}
	if !network.transport_queue(&connection.transport, packet) {
		connection.failed = true
		return false
	}
	return true
}

@(private)
server_error :: proc(server: ^Server, index: int, code: network.Error_Code, close_after := false) {
	packet := network.Packet{kind = .Error, payload_size = 1}
	packet.payload[0] = u8(code)
	server_queue(server, index, packet)
	server.stats.rejected += 1
	if close_after {
		connection := &server.connections[index]
		connection.closing = true
		connection.close_started = time.tick_now()
	}
}

@(private)
server_disconnect :: proc(server: ^Server, index: int) {
	connection := &server.connections[index]
	if !connection.transport.open {return}
	room_index, peer := connection.room, connection.peer
	if connection.udp_issued {delete_key(&server.udp_sessions, connection.udp_token)}
	network.transport_close(&connection.transport)
	connection^ = {room = -1}
	server.stats.connections -= 1
	server.stats.disconnected += 1
	if room_index < 0 || !server.rooms[room_index].active {return}
	room := &server.rooms[room_index]
	if peer == 1 {
		room.active = false
		server.stats.rooms -= 1
		for &guest, guest_index in server.connections {
			if guest.transport.open && guest.room == room_index {
				server_queue(server, guest_index, network.Packet{kind = .Room_Closed})
				guest.room = -1
				guest.closing = true
				if guest.udp_issued {delete_key(&server.udp_sessions, guest.udp_token)}
				guest.udp_issued, guest.udp_bound = false, false
				guest.close_started = time.tick_now()
			}
		}
	} else {
		room.members -= 1
		for &guest, guest_index in server.connections {
			if guest.transport.open && guest.room == room_index {
				server_queue(server, guest_index, network.Packet{kind = .Peer_Left, peer = peer})
			}
		}
	}
}

@(private)
server_handle :: proc(server: ^Server, index: int, value: network.Packet) {
	packet := value
	connection := &server.connections[index]
	#partial switch packet.kind {
	case .Create:
		if connection.room >= 0 || packet.peer != 0 || packet.payload_size != 1 || packet.payload[0] < 2 || packet.payload[0] > network.MAX_ROOM_PEERS {
			server_error(server, index, .Invalid_Request); return
		}
		free := -1
		for room, room_index in server.rooms {if !room.active {free = room_index; break}}
		if free < 0 {server_error(server, index, .Server_Full); return}
		room := &server.rooms[free]
		room^ = {active = true, capacity = int(packet.payload[0]), members = 1, next_peer = 2}
		// A collision is extraordinarily unlikely; still reject duplicates rather
		// than accidentally allowing admission to another room.
		for {
			entropy: [network.CODE_SIZE / 2]u8
			crypto.rand_bytes(entropy[:])
			alphabet := "0123456789ABCDEF"
			for value, byte_index in entropy {
				room.code[byte_index * 2] = alphabet[value >> 4]
				room.code[byte_index * 2 + 1] = alphabet[value & 15]
			}
			duplicate := false
			for other, other_index in server.rooms {
				if other_index != free && other.active && other.code == room.code {duplicate = true; break}
			}
			if !duplicate {break}
		}
		connection.room, connection.peer = free, 1
		server.stats.rooms += 1
		welcome := network.Packet{kind = .Welcome, peer = 1, payload_size = network.CODE_SIZE}
		copy(welcome.payload[:], room.code[:])
		server_queue(server, index, welcome)
	case .Join:
		if connection.room >= 0 || packet.peer != 0 || packet.payload_size != network.CODE_SIZE {
			server_error(server, index, .Invalid_Request); return
		}
		code: [network.CODE_SIZE]u8
		copy(code[:], packet.payload[:network.CODE_SIZE])
		found := -1
		for room, room_index in server.rooms {if room.active && room.code == code {found = room_index; break}}
		if found < 0 {server_error(server, index, .Room_Not_Found); return}
		room := &server.rooms[found]
		if room.members >= room.capacity || room.next_peer == 0 {
			server_error(server, index, .Room_Full); return
		}
		connection.room, connection.peer = found, room.next_peer
		room.next_peer += 1
		room.members += 1
		joined := network.Packet{kind = .Joined, peer = connection.peer, payload_size = network.CODE_SIZE}
		copy(joined.payload[:], room.code[:])
		server_queue(server, index, joined)
		for &other, other_index in server.connections {
			if other_index != index && other.transport.open && other.room == found && !other.closing {
				server_queue(server, other_index, network.Packet{kind = .Peer_Joined, peer = connection.peer})
				server_queue(server, index, network.Packet{kind = .Peer_Joined, peer = other.peer})
			}
		}
	case .Data:
		if connection.room < 0 {server_error(server, index, .Not_In_Room); return}
		if connection.peer != 1 && packet.peer != 1 {server_error(server, index, .Forbidden); return}
		if packet.peer == connection.peer {server_error(server, index, .Forbidden); return}
		forwarded := packet
		forwarded.peer = connection.peer // Never trust a claimed sender identity.
		delivered := false
		for &target, target_index in server.connections {
			if target_index == index || !target.transport.open || target.failed || target.closing || target.room != connection.room {continue}
			if packet.peer == 0 || target.peer == packet.peer {
				delivered = true // A dropped unreliable send is not a forbidden target.
				if server_forward_data(server, target_index, forwarded) {server.stats.forwarded += 1}
			}
		}
		if !delivered && packet.peer != 0 {
			// A host can send before receiving the TCP Peer_Left event. Drop
			// realtime data to an admitted peer whose connection has departed or
			// is closing, rather than turning that ordinary race into a room error.
			room := &server.rooms[connection.room]
			if connection.peer == 1 && packet.peer >= 2 && packet.peer < room.next_peer {return}
			server_error(server, index, .Forbidden)
		}
	case .Ping:
		if packet.peer != 0 || packet.payload_size != 0 {server_error(server, index, .Invalid_Request); return}
		server_queue(server, index, network.Packet{kind = .Pong})
	case .UDP_Enable:
		if packet.peer != 0 || packet.payload_size != 0 {server_error(server, index, .Invalid_Request); return}
		if !server.udp_open {server_error(server, index, .UDP_Unavailable); return}
		if !connection.udp_issued {
			for {
				crypto.rand_bytes(connection.udp_token[:])
				_, duplicate := server.udp_sessions[connection.udp_token]
				if connection.udp_token != ([network.UDP_TOKEN_SIZE]u8{}) && !duplicate {break}
			}
			connection.udp_issued = true
			server.udp_sessions[connection.udp_token] = index
		}
		response := network.Packet{kind = .UDP_Session, payload_size = network.UDP_TOKEN_SIZE}
		copy(response.payload[:network.UDP_TOKEN_SIZE], connection.udp_token[:])
		server_queue(server, index, response)
	case .Leave:
		if packet.peer != 0 || packet.payload_size != 0 {server_error(server, index, .Invalid_Request); return}
		server_disconnect(server, index)
	case:
		server_error(server, index, .Invalid_Request, true)
	}
}
