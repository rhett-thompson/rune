package network

import "core:net"
import "core:time"

CLIENT_HEARTBEAT_INTERVAL :: 1 * time.Second
CLIENT_TIMEOUT :: 30 * time.Second

Client_Status :: enum {
	Disconnected,
	Connected,
	Joining,
	In_Room,
}

Client :: struct {
	transport:     Transport,
	status:        Client_Status,
	peer_id:       u32,
	room_code:     [CODE_SIZE]u8,
	is_host:       bool,
	last_received: time.Tick,
	last_ping:     time.Tick,
	udp_socket: net.UDP_Socket,
	udp_remote: net.Endpoint,
	udp_token: [UDP_TOKEN_SIZE]u8,
	udp_requested, udp_ready, udp_failed, udp_open, udp_session: bool,
	udp_started, udp_last_bind, udp_last_received: time.Tick,
	udp_send_sequence, udp_bind_sequence: u32,
	udp_replay: Replay_Window,
	udp_datagrams_sent, udp_datagrams_received, udp_datagrams_rejected, udp_dropped: u64,
	measurements: Client_Measurements,
}

// DNS resolution and the initial TCP dial are synchronous. Subsequent socket
// work is nonblocking; poll receives events and retries pending output.
connect :: proc(client: ^Client, server: string, use_udp: bool = false) -> net.Network_Error {
	if client == nil { return net.Dial_Error.Invalid_Argument }
	disconnect(client)
	client.udp_requested, client.udp_failed = use_udp, false
	client.measurements = {}
	client.transport.traffic, client.transport.last_ping_sent = {}, {}
	client.udp_datagrams_sent, client.udp_datagrams_received, client.udp_datagrams_rejected, client.udp_dropped = 0, 0, 0, 0
	socket, error := net.dial_tcp(server)
	if error != nil { return error }
	if !transport_init(&client.transport, socket) { return net.Set_Blocking_Error.Unknown }
	client.status = .Connected
	client.last_received = time.tick_now()
	client.last_ping = client.last_received
	if use_udp {
		remote, endpoint_error := net.peer_endpoint(socket)
		if endpoint_error != nil {client_udp_fail(client); return endpoint_error}
		if error := client_udp_start(client, remote); error != nil {client_udp_fail(client); return error}
		if !transport_queue(&client.transport, Packet{kind = .UDP_Enable}) || !transport_flush(&client.transport) {
			client_udp_fail(client)
			return net.TCP_Send_Error.Connection_Closed
		}
	}
	return nil
}

// A connection has a single room lifetime. Closing it is also the leave action.
disconnect :: proc(client: ^Client) {
	if client == nil { return }
	transport_close(&client.transport)
	if client.udp_open {net.close(client.udp_socket)}
	client.udp_socket, client.udp_remote, client.udp_token = {}, {}, {}
	client.udp_open, client.udp_ready, client.udp_session = false, false, false
	client.udp_started, client.udp_last_bind, client.udp_last_received = {}, {}, {}
	client.udp_send_sequence, client.udp_bind_sequence, client.udp_replay = 0, 0, {}
	client.status = .Disconnected
	client.peer_id = 0
	client.room_code = {}
	client.is_host = false
}

create_room :: proc(client: ^Client, capacity: u8 = 8) -> bool {
	if client == nil || client.status != .Connected || capacity < 2 || int(capacity) > MAX_ROOM_PEERS { return false }
	packet := Packet{kind = .Create, payload_size = 1}
	packet.payload[0] = capacity
	if !transport_queue(&client.transport, packet) { return false }
	client.status = .Joining
	client.is_host = true
	return true
}

join_room :: proc(client: ^Client, code: string) -> bool {
	if client == nil || client.status != .Connected || !room_code_valid(transmute([]u8)code) { return false }
	packet := Packet{kind = .Join, payload_size = CODE_SIZE}
	copy(packet.payload[:CODE_SIZE], transmute([]u8)code)
	if !transport_queue(&client.transport, packet) { return false }
	client.status = .Joining
	client.is_host = false
	return true
}

// Hosts target an individual guest or broadcast with peer 0. Guests can only
// send to host peer 1. The server authenticates and replaces the sender ID.
// Attempt delivery immediately. Backpressure retains unsent bytes for poll;
// a fatal socket error disconnects the client and returns false.
send :: proc(client: ^Client, payload: []u8, peer: u32 = 0) -> bool {
	if client == nil || client.status != .In_Room || len(payload) > MAX_PAYLOAD { return false }
	if !client.is_host && peer != 1 { return false }
	if client.is_host && peer == 1 { return false }
	packet := Packet{kind = .Data, peer = peer, payload_size = len(payload)}
	copy(packet.payload[:len(payload)], payload)
	if client.udp_ready {return client_udp_send(client, packet)}
	if !transport_queue(&client.transport, packet) { return false }
	if !transport_flush(&client.transport) { disconnect(client); return false }
	return true
}

client_apply_packet :: proc(client: ^Client, value: Packet) -> bool {
	packet := value
	#partial switch packet.kind {
	case .Welcome, .Joined:
		if client.status != .Joining || packet.peer == 0 || packet.payload_size != CODE_SIZE || !room_code_valid(packet.payload[:CODE_SIZE]) {
			return false
		}
		if (packet.kind == .Welcome) != client.is_host || (packet.peer == 1) != client.is_host { return false }
		client.peer_id = packet.peer
		copy(client.room_code[:], packet.payload[:CODE_SIZE])
		client.status = .In_Room
	case .Peer_Joined, .Peer_Left:
		if client.status != .In_Room || packet.peer == 0 || packet.peer == client.peer_id || packet.payload_size != 0 { return false }
	case .Data:
		if client.status != .In_Room || packet.peer == 0 || packet.peer == client.peer_id { return false }
		if !client.is_host && packet.peer != 1 { return false }
	case .Room_Closed:
		if client.status != .In_Room || packet.payload_size != 0 { return false }
		disconnect(client)
	case .Pong:
		if packet.payload_size != 0 { return false }
		client_tcp_pong(client, time.tick_now())
	case .UDP_Session:
		if !client.udp_requested || !client.udp_open || packet.peer != 0 || packet.payload_size != UDP_TOKEN_SIZE {return false}
		token: [UDP_TOKEN_SIZE]u8
		copy(token[:], packet.payload[:UDP_TOKEN_SIZE])
		if !udp_token_valid(token) || (client.udp_session && token != client.udp_token) {return false}
		client.udp_token, client.udp_session = token, true
	case .Error:
		if packet.payload_size != 1 || packet.payload[0] < u8(Error_Code.Invalid_Request) || packet.payload[0] > u8(Error_Code.UDP_Unavailable) {
			return false
		}
		if client.status == .Joining {
			client.status = .Connected
			client.is_host = false
		}
	case:
		return false
	}
	return true
}

// Returns one owned event per call. Drain available events each frame until
// available is false; ok becomes false on disconnect, timeout, or bad protocol.
// A Room_Closed event is returned once with ok true and resets the client.
poll :: proc(client: ^Client) -> (packet: Packet, available: bool, ok: bool) {
	if client == nil || client.status == .Disconnected { return {}, false, false }
	now := time.tick_now()
	// Deliver buffered and newly arrived events before writing. A server may
	// send Room_Closed and close while a guest still has application data queued;
	// discovering the send failure first would erase the final event.
	valid: bool
	packet, available, valid = transport_next(&client.transport)
	if !valid { disconnect(client); return {}, false, false }
	if !available {
		if !transport_receive(&client.transport) { disconnect(client); return {}, false, false }
		packet, available, valid = transport_next(&client.transport)
		if !valid { disconnect(client); return {}, false, false }
	}
	if available {
		client.last_received = now
		if !client_apply_packet(client, packet) { disconnect(client); return {}, false, false }
		if packet.kind == .Error && packet.payload[0] == u8(Error_Code.UDP_Unavailable) && client.udp_requested {
			client_udp_fail(client)
			return {}, false, false
		}
		if packet.kind != .UDP_Session {
			if client.status != .Disconnected && !client_udp_maintenance(client, now) {return {}, false, false}
			return packet, true, true
		}
	}
	if time.tick_diff(client.last_received, now) >= CLIENT_TIMEOUT { disconnect(client); return {}, false, false }
	if time.tick_diff(client.last_ping, now) >= CLIENT_HEARTBEAT_INTERVAL && !client.measurements.tcp_ping_pending {
		if !transport_queue(&client.transport, Packet{kind = .Ping}) { disconnect(client); return {}, false, false }
		client.measurements.tcp_ping_pending = true
		client.measurements.tcp_ping_queued = now
		client.last_ping = now
	}
	if !transport_flush(&client.transport) { disconnect(client); return {}, false, false }
	if !client_udp_maintenance(client, now) {return {}, false, false}
	if client.udp_open {return client_udp_poll(client, now)}
	return {}, false, true
}
