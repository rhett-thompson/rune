package main

import "core:math"
import "core:time"
import "rune:network"

PEER_PROBE_VERSION :: u8(1)
PEER_PROBE_SIZE :: 6
PEER_PROBE_CAPACITY :: 8
PEER_PROBE_INTERVAL :: time.Second
PEER_PROBE_TIMEOUT :: 3 * time.Second

Peer_Probe_Kind :: enum u8 {Ping = 5, Pong = 6}
Peer_Probe :: struct {nonce: u32, sent: time.Tick, active: bool}

// Measures a round trip through the relay and the other game's event pump.
// Probes are independent of movement commands, acknowledgments, and snapshots.
Peer_Stats :: struct {
	peer: u32,
	has_rtt: bool,
	rtt_ms, jitter_ms, last_sample_ms: f64,
	last_reply: time.Tick,
	probes_sent, probes_received, probes_timed_out, probes_rejected: u64,
	pings_received: u64,
	pending: [PEER_PROBE_CAPACITY]Peer_Probe,
	pending_count, cursor: int,
	next_nonce: u32,
	last_send: time.Tick,
	has_last_send: bool,
}

encode_peer_probe :: proc(kind: Peer_Probe_Kind, nonce: u32, buffer: []u8) -> (int, bool) {
	if len(buffer) < PEER_PROBE_SIZE || (kind != .Ping && kind != .Pong) {return 0, false}
	buffer[0], buffer[1] = PEER_PROBE_VERSION, u8(kind)
	buffer[2] = u8(nonce >> 24)
	buffer[3] = u8((nonce >> 16) & 0xff)
	buffer[4] = u8((nonce >> 8) & 0xff)
	buffer[5] = u8(nonce & 0xff)
	return PEER_PROBE_SIZE, true
}

decode_peer_probe :: proc(buffer: []u8) -> (Peer_Probe_Kind, u32, bool) {
	if len(buffer) != PEER_PROBE_SIZE || buffer[0] != PEER_PROBE_VERSION ||
	   (buffer[1] != u8(Peer_Probe_Kind.Ping) && buffer[1] != u8(Peer_Probe_Kind.Pong)) {return {}, 0, false}
	kind := Peer_Probe_Kind(buffer[1])
	nonce := (u32(buffer[2]) << 24) | (u32(buffer[3]) << 16) | (u32(buffer[4]) << 8) | u32(buffer[5])
	return kind, nonce, true
}

peer_stats_expire :: proc(stats: ^Peer_Stats, now: time.Tick) {
	if stats.has_rtt && time.tick_diff(stats.last_reply, now) >= PEER_PROBE_TIMEOUT {stats.has_rtt = false}
	for &probe in stats.pending {
		if !probe.active || time.tick_diff(probe.sent, now) < PEER_PROBE_TIMEOUT {continue}
		probe.active = false
		stats.pending_count -= 1
		stats.probes_timed_out += 1
	}
}

// Record only probes that were successfully handed to network.send. This pure
// operation also permits deterministic delay/loss tests without sleeping.
peer_stats_record :: proc(stats: ^Peer_Stats, peer, nonce: u32, now: time.Tick) -> bool {
	if peer == 0 {return false}
	if stats.peer != peer {stats^ = {peer = peer}}
	for probe in stats.pending {if probe.active && probe.nonce == nonce {return false}}
	if stats.pending_count >= PEER_PROBE_CAPACITY {return false}
	for offset in 0..<PEER_PROBE_CAPACITY {
		index := (stats.cursor + offset) % PEER_PROBE_CAPACITY
		if stats.pending[index].active {continue}
		stats.pending[index] = {nonce = nonce, sent = now, active = true}
		stats.pending_count += 1
		stats.cursor = (index + 1) % PEER_PROBE_CAPACITY
		stats.next_nonce, stats.last_send, stats.has_last_send = nonce, now, true
		stats.probes_sent += 1
		return true
	}
	return false
}

@(private)
peer_stats_remote_valid :: proc(client: ^network.Client, peer: u32) -> bool {
	if client == nil || client.status != .In_Room || peer == 0 || client.peer_id == 0 || peer == client.peer_id {return false}
	if client.is_host {return client.peer_id == 1 && peer > 1}
	return client.peer_id > 1 && peer == 1
}

// A missing/changed opponent starts a new measurement lifetime. The caller
// supplies zero while waiting for another player or after that player leaves.
peer_stats_update :: proc(stats: ^Peer_Stats, client: ^network.Client, remote_peer: u32, now: time.Tick) -> bool {
	if !peer_stats_remote_valid(client, remote_peer) {stats^ = {}; return true}
	if stats.peer != remote_peer {stats^ = {peer = remote_peer}}
	peer_stats_expire(stats, now)
	if stats.has_last_send && time.tick_diff(stats.last_send, now) < PEER_PROBE_INTERVAL {return true}
	if stats.pending_count >= PEER_PROBE_CAPACITY {return true}
	nonce := stats.next_nonce + 1 // Zero is a valid nonce after u32 wrap.
	buffer: [PEER_PROBE_SIZE]u8
	size, encoded := encode_peer_probe(.Ping, nonce, buffer[:])
	assert(encoded)
	if !network.send(client, buffer[:size], remote_peer) {return false}
	assert(peer_stats_record(stats, remote_peer, nonce, now))
	return true
}

// recognized prevents probes from reaching input/snapshot decoders. valid
// reports framing/peer checks; ok is false only when a valid echo cannot send.
// Structurally valid late/duplicate/unmatched pongs are consumed without a sample.
peer_stats_receive :: proc(stats: ^Peer_Stats, client: ^network.Client, remote_peer: u32, packet: network.Packet, now: time.Tick) -> (recognized, valid, ok: bool) {
	packet := packet
	if packet.kind != .Data || packet.payload_size < 2 || packet.payload_size > len(packet.payload) {return false, false, true}
	if packet.payload[1] != u8(Peer_Probe_Kind.Ping) && packet.payload[1] != u8(Peer_Probe_Kind.Pong) {return false, false, true}
	kind, nonce, decoded := decode_peer_probe(packet.payload[:packet.payload_size])
	if !decoded || !peer_stats_remote_valid(client, remote_peer) || packet.peer != remote_peer {
		stats.probes_rejected += 1
		return true, false, true
	}
	if stats.peer != remote_peer {stats^ = {peer = remote_peer}}
	peer_stats_expire(stats, now)
	if kind == .Ping {
		stats.pings_received += 1
		buffer: [PEER_PROBE_SIZE]u8
		size, encoded := encode_peer_probe(.Pong, nonce, buffer[:])
		assert(encoded)
		return true, true, network.send(client, buffer[:size], packet.peer)
	}
	for &probe in stats.pending {
		if !probe.active || probe.nonce != nonce {continue}
		elapsed := time.tick_diff(probe.sent, now)
		if elapsed < 0 {break}
		probe.active = false
		stats.pending_count -= 1
		sample := f64(elapsed) / f64(time.Millisecond)
		if !stats.has_rtt {
			stats.rtt_ms, stats.jitter_ms, stats.has_rtt = sample, 0, true
		} else {
			stats.rtt_ms += (sample - stats.rtt_ms) * 0.125
			stats.jitter_ms += (math.abs(sample - stats.last_sample_ms) - stats.jitter_ms) * 0.25
		}
		stats.last_sample_ms, stats.last_reply = sample, now
		stats.probes_received += 1
		return true, true, true
	}
	stats.probes_rejected += 1
	return true, true, true
}
