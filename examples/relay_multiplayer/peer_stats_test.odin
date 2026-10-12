package main

import "core:math"
import "core:net"
import "core:testing"
import "core:time"
import "rune:network"

peer_test_client :: proc(peer := u32(1)) -> network.Client {
	return {status = .In_Room, peer_id = peer, is_host = peer == 1}
}

peer_test_packet :: proc(peer: u32, kind: Peer_Probe_Kind, nonce: u32) -> network.Packet {
	packet := network.Packet{kind = .Data, peer = peer}
	size, valid := encode_peer_probe(kind, nonce, packet.payload[:])
	assert(valid)
	packet.payload_size = size
	return packet
}

peer_test_pong :: proc(stats: ^Peer_Stats, client: ^network.Client, peer, nonce: u32, now: time.Tick) {
	recognized, valid, ok := peer_stats_receive(stats, client, peer, peer_test_packet(peer, .Pong, nonce), now)
	assert(recognized && valid && ok)
}

peer_test_tcp_packet :: proc(transport: ^network.Transport) -> network.Packet {
	started := time.tick_now()
	for time.tick_since(started) < time.Second {
		assert(network.transport_receive(transport))
		packet, available, valid := network.transport_next(transport)
		assert(valid)
		if available {return packet}
		time.sleep(time.Millisecond)
	}
	panic("peer probe did not reach its socket")
}

@(test)
peer_probe_codec_nonce_boundaries_and_exact_frame_validation :: proc(t: ^testing.T) {
	buffer: [PEER_PROBE_SIZE + 1]u8
	fixture := [PEER_PROBE_SIZE]u8{1, 5, 0x12, 0x34, 0x56, 0x78}
	size, encoded := encode_peer_probe(.Ping, 0x12345678, buffer[:])
	testing.expect(t, encoded && size == len(fixture))
	for byte, index in fixture {testing.expect_value(t, buffer[index], byte)}
	for kind in ([2]Peer_Probe_Kind{.Ping, .Pong}) {
		for nonce in ([]u32{0, 1, 0xffffffff}) {
			size, encoded = encode_peer_probe(kind, nonce, buffer[:])
			decoded_kind, decoded_nonce, valid := decode_peer_probe(buffer[:size])
			testing.expect(t, encoded && valid && decoded_kind == kind && decoded_nonce == nonce)
		}
	}
	for size in 0..<PEER_PROBE_SIZE {_, _, valid := decode_peer_probe(fixture[:size]); testing.expect(t, !valid)}
	_, _, valid := decode_peer_probe(buffer[:])
	testing.expect(t, !valid)
	for index in ([]int{0, 1}) {
		bad := fixture
		bad[index] = 99
		_, _, valid = decode_peer_probe(bad[:])
		testing.expect(t, !valid)
	}
	_, encoded = encode_peer_probe(.Ping, 1, buffer[:PEER_PROBE_SIZE - 1])
	testing.expect(t, !encoded)
}

@(test)
peer_rtt_first_sample_and_jitter_use_elapsed_roundtrip_and_consecutive_variation :: proc(t: ^testing.T) {
	stats: Peer_Stats
	client := peer_test_client()
	start := time.tick_add(time.Tick{}, time.Second)
	assert(peer_stats_record(&stats, 2, 1, start))
	peer_test_pong(&stats, &client, 2, 1, time.tick_add(start, 40 * time.Millisecond))
	testing.expect(t, stats.has_rtt && stats.rtt_ms == 40 && stats.jitter_ms == 0 && stats.pending_count == 0)
	assert(peer_stats_record(&stats, 2, 2, time.tick_add(start, time.Second)))
	peer_test_pong(&stats, &client, 2, 2, time.tick_add(start, time.Second + 80 * time.Millisecond))
	testing.expect(t, stats.rtt_ms == 45 && stats.jitter_ms == 10)
	assert(peer_stats_record(&stats, 2, 3, time.tick_add(start, 2 * time.Second)))
	peer_test_pong(&stats, &client, 2, 3, time.tick_add(start, 2 * time.Second + 80 * time.Millisecond))
	testing.expect(t, stats.rtt_ms == 49.375 && stats.jitter_ms == 7.5, "identical consecutive samples reduce jitter even while RTT smooths")
	testing.expect(t, stats.probes_sent == 3 && stats.probes_received == 3 && stats.probes_timed_out == 0)
}

@(test)
peer_rtt_matches_out_of_order_replies_and_ignores_duplicate_and_forged_peer :: proc(t: ^testing.T) {
	stats: Peer_Stats
	client := peer_test_client()
	start := time.tick_add(time.Tick{}, time.Second)
	assert(peer_stats_record(&stats, 2, 1, start))
	assert(peer_stats_record(&stats, 2, 2, time.tick_add(start, 10 * time.Millisecond)))
	before := stats
	recognized, valid, ok := peer_stats_receive(&stats, &client, 2, peer_test_packet(3, .Pong, 1), time.tick_add(start, 15 * time.Millisecond))
	testing.expect(t, recognized && !valid && ok && !stats.has_rtt && stats.pending == before.pending && stats.pending_count == 2)
	peer_test_pong(&stats, &client, 2, 2, time.tick_add(start, 30 * time.Millisecond))
	peer_test_pong(&stats, &client, 2, 1, time.tick_add(start, 40 * time.Millisecond))
	testing.expect(t, stats.rtt_ms == 22.5 && stats.jitter_ms == 5 && stats.pending_count == 0 && stats.probes_received == 2)
	before = stats
	peer_test_pong(&stats, &client, 2, 2, time.tick_add(start, 500 * time.Millisecond))
	testing.expect(t, stats.probes_received == before.probes_received && stats.rtt_ms == before.rtt_ms && stats.jitter_ms == before.jitter_ms)
	testing.expect(t, stats.probes_rejected == 2)
}

@(test)
peer_rtt_expiration_counts_loss_once_and_late_reply_does_not_change_measurement :: proc(t: ^testing.T) {
	stats: Peer_Stats
	client := peer_test_client()
	start := time.tick_add(time.Tick{}, time.Second)
	assert(peer_stats_record(&stats, 2, 7, start))
	assert(peer_stats_record(&stats, 2, 8, time.tick_add(start, time.Second)))
	peer_stats_expire(&stats, time.tick_add(start, PEER_PROBE_TIMEOUT - time.Nanosecond))
	testing.expect(t, stats.pending_count == 2 && stats.probes_timed_out == 0)
	peer_test_pong(&stats, &client, 2, 7, time.tick_add(start, PEER_PROBE_TIMEOUT))
	testing.expect(t, !stats.has_rtt && stats.pending_count == 1 && stats.probes_timed_out == 1)
	peer_stats_expire(&stats, time.tick_add(start, 4 * time.Second))
	peer_stats_expire(&stats, time.tick_add(start, 8 * time.Second))
	testing.expect(t, stats.pending_count == 0 && stats.probes_timed_out == 2 && stats.probes_received == 0)
	peer_test_pong(&stats, &client, 2, 8, time.tick_add(start, 9 * time.Second))
	testing.expect(t, !stats.has_rtt && stats.probes_timed_out == 2)
}

@(test)
peer_rtt_availability_expires_at_reply_deadline_and_fresh_reply_reinitializes :: proc(t: ^testing.T) {
	stats: Peer_Stats
	client := peer_test_client()
	start := time.tick_add(time.Tick{}, time.Second)
	assert(peer_stats_record(&stats, 2, 1, start))
	peer_test_pong(&stats, &client, 2, 1, time.tick_add(start, 40 * time.Millisecond))
	assert(peer_stats_record(&stats, 2, 2, time.tick_add(start, time.Second)))
	peer_test_pong(&stats, &client, 2, 2, time.tick_add(start, time.Second + 80 * time.Millisecond))
	testing.expect(t, stats.has_rtt && stats.rtt_ms == 45 && stats.jitter_ms == 10)
	deadline := time.tick_add(stats.last_reply, PEER_PROBE_TIMEOUT)
	peer_stats_expire(&stats, time.tick_add(deadline, -time.Nanosecond))
	testing.expect(t, stats.has_rtt, "the last measurement remains available before its three-second deadline")
	cached := stats
	peer_stats_expire(&stats, deadline)
	testing.expect(t, !stats.has_rtt, "a stale RTT must stop displaying at the deadline")
	testing.expect(t, stats.rtt_ms == cached.rtt_ms && stats.jitter_ms == cached.jitter_ms && stats.last_reply == cached.last_reply)
	testing.expect(t, stats.probes_sent == cached.probes_sent && stats.probes_received == cached.probes_received && stats.probes_timed_out == cached.probes_timed_out)
	assert(peer_stats_record(&stats, 2, 3, deadline))
	peer_test_pong(&stats, &client, 2, 3, time.tick_add(deadline, 120 * time.Millisecond))
	testing.expect(t, stats.has_rtt && stats.rtt_ms == 120 && stats.jitter_ms == 0, "a fresh response starts a new estimate instead of averaging with stale samples")
	testing.expect(t, stats.probes_received == 3 && stats.pending_count == 0 && stats.probes_timed_out == 0)
}

@(test)
peer_probe_pending_ring_is_bounded_and_nonce_wrap_has_no_old_reply_alias :: proc(t: ^testing.T) {
	stats: Peer_Stats
	client := peer_test_client()
	start := time.tick_add(time.Tick{}, time.Second)
	for index in 0..<PEER_PROBE_CAPACITY {assert(peer_stats_record(&stats, 2, u32(index + 1), start))}
	before := stats
	testing.expect(t, !peer_stats_record(&stats, 2, 99, start) && stats == before)
	testing.expect(t, !peer_stats_record(&stats, 2, 1, start) && stats == before)
	peer_test_pong(&stats, &client, 2, 4, time.tick_add(start, time.Millisecond))
	assert(peer_stats_record(&stats, 2, 99, start))
	testing.expect(t, stats.pending_count == PEER_PROBE_CAPACITY)
	stats = {}
	assert(peer_stats_record(&stats, 2, 0xffffffff, start))
	assert(peer_stats_record(&stats, 2, 0, time.tick_add(start, time.Millisecond)))
	peer_test_pong(&stats, &client, 2, 0, time.tick_add(start, 11 * time.Millisecond))
	peer_test_pong(&stats, &client, 2, 0xffffffff, time.tick_add(start, 20 * time.Millisecond))
	testing.expect(t, stats.probes_received == 2 && stats.pending_count == 0 && stats.rtt_ms == 11.25)
}

@(test)
peer_probe_malformed_and_unrelated_data_do_not_consume_pending_samples :: proc(t: ^testing.T) {
	stats: Peer_Stats
	client := peer_test_client()
	start := time.tick_add(time.Tick{}, time.Second)
	assert(peer_stats_record(&stats, 2, 1, start))
	for bad_version in ([2]bool{false, true}) {
		packet := peer_test_packet(2, .Pong, 1)
		if bad_version {packet.payload[0] = 2} else {packet.payload_size -= 1}
		recognized, valid, ok := peer_stats_receive(&stats, &client, 2, packet, start)
		testing.expect(t, recognized && !valid && ok && stats.pending_count == 1 && !stats.has_rtt)
	}
	unrelated := network.Packet{kind = .Data, peer = 2, payload_size = 2}
	unrelated.payload[0], unrelated.payload[1] = 1, 4
	before := stats
	recognized, _, ok := peer_stats_receive(&stats, &client, 2, unrelated, start)
	testing.expect(t, !recognized && ok && stats == before, "movement payload belongs to the existing game decoder")
	peer_test_pong(&stats, &client, 2, 1, time.tick_add(start, -time.Millisecond))
	testing.expect(t, !stats.has_rtt && stats.pending_count == 1, "a backward caller clock cannot create a negative RTT")
}

@(test)
peer_probe_absent_target_disconnected_client_and_changed_peer_reset_measurements :: proc(t: ^testing.T) {
	start := time.tick_add(time.Tick{}, time.Second)
	client := peer_test_client()
	stats: Peer_Stats
	assert(peer_stats_record(&stats, 2, 1, start))
	peer_test_pong(&stats, &client, 2, 1, time.tick_add(start, time.Millisecond))
	testing.expect(t, peer_stats_update(&stats, &client, 0, start) && stats == Peer_Stats{})
	assert(peer_stats_record(&stats, 2, 1, start))
	client.status = .Disconnected
	testing.expect(t, peer_stats_update(&stats, &client, 2, start) && stats == Peer_Stats{})
	client = peer_test_client()
	assert(peer_stats_record(&stats, 2, 1, start))
	assert(peer_stats_record(&stats, 3, 1, start))
	testing.expect(t, stats.peer == 3 && stats.probes_sent == 1 && stats.pending_count == 1 && !stats.has_rtt)
	before := stats
	testing.expect(t, !peer_stats_record(&stats, 0, 1, start) && stats == before)
	// A valid room identity with no open transport models a failed send.
	// Attempts cannot become outstanding RTT measurements after that failure.
	stats = {}
	testing.expect(t, !peer_stats_update(&stats, &client, 2, start))
	testing.expect(t, stats.pending_count == 0 && stats.probes_sent == 0 && !stats.has_last_send)
	recognized, valid, ok := peer_stats_receive(&stats, &client, 2, peer_test_packet(2, .Ping, 1), start)
	testing.expect(t, recognized && valid && !ok && !stats.has_rtt && stats.probes_received == 0)
}

@(test)
peer_probe_update_and_echo_send_exact_targeted_game_data_without_measurement_on_ping :: proc(t: ^testing.T) {
	listener, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	assert(listen_error == nil)
	defer net.close(listener)
	endpoint, endpoint_error := net.bound_endpoint(listener)
	assert(endpoint_error == nil)
	client: network.Client
	assert(network.connect(&client, net.endpoint_to_string(endpoint)) == nil)
	defer network.disconnect(&client)
	socket, _, accept_error := net.accept_tcp(listener)
	assert(accept_error == nil)
	transport: network.Transport
	assert(network.transport_init(&transport, socket))
	defer network.transport_close(&transport)
	client.status, client.peer_id, client.is_host = .In_Room, 1, true
	stats: Peer_Stats
	start := time.tick_add(time.Tick{}, time.Second)
	assert(peer_stats_update(&stats, &client, 2, start))
	packet := peer_test_tcp_packet(&transport)
	kind, nonce, valid := decode_peer_probe(packet.payload[:packet.payload_size])
	testing.expect(t, packet.kind == .Data && packet.peer == 2 && valid && kind == .Ping && nonce == 1)
	testing.expect(t, stats.probes_sent == 1 && stats.pending_count == 1 && !stats.has_rtt)
	before := stats
	assert(peer_stats_update(&stats, &client, 2, time.tick_add(start, PEER_PROBE_INTERVAL - time.Nanosecond)))
	testing.expect(t, stats == before, "render frame frequency must not increase probe frequency")
	assert(peer_stats_update(&stats, &client, 2, time.tick_add(start, PEER_PROBE_INTERVAL)))
	packet = peer_test_tcp_packet(&transport)
	_, nonce, valid = decode_peer_probe(packet.payload[:packet.payload_size])
	testing.expect(t, valid && nonce == 2 && stats.probes_sent == 2)
	recognized, echo_valid, ok := peer_stats_receive(&stats, &client, 2, peer_test_packet(2, .Ping, 0x12345678), time.tick_add(start, time.Second))
	testing.expect(t, recognized && echo_valid && ok && !stats.has_rtt && stats.probes_received == 0 && stats.pings_received == 1)
	packet = peer_test_tcp_packet(&transport)
	kind, nonce, valid = decode_peer_probe(packet.payload[:packet.payload_size])
	testing.expect(t, packet.peer == 2 && valid && kind == .Pong && nonce == 0x12345678)
	peer_test_pong(&stats, &client, 2, 2, time.tick_add(start, time.Second + 35 * time.Millisecond))
	testing.expect(t, stats.has_rtt && math.abs(stats.rtt_ms - 35) < 0.001)
}
