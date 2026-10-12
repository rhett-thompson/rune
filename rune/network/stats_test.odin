package network

import "core:testing"
import "core:time"

@(test)
client_stats_rtt_matches_probes_once_and_smooths_variation :: proc(t: ^testing.T) {
	start := time.tick_now()
	client := Client{udp_requested = true}
	client_bind_sent(&client, 7, start)
	client_bind_acknowledged(&client, 8, time.tick_add(start, 100*time.Millisecond))
	testing.expect(t, !stats(&client).has_relay_rtt, "an unmatched bind acknowledgement cannot create an RTT")
	client_bind_acknowledged(&client, 7, time.tick_add(start, 100*time.Millisecond))
	first := stats(&client)
	testing.expect(t, first.has_relay_rtt && first.relay_rtt_ms == 100 && first.relay_rtt_variation_ms == 50)
	client_bind_acknowledged(&client, 7, time.tick_add(start, 900*time.Millisecond))
	testing.expect(t, stats(&client).relay_rtt_ms == first.relay_rtt_ms, "a duplicate reply cannot resample a probe")
	client_bind_sent(&client, 8, time.tick_add(start, 200*time.Millisecond))
	client_bind_acknowledged(&client, 8, time.tick_add(start, 280*time.Millisecond))
	second := stats(&client)
	testing.expect(t, second.relay_rtt_ms == 97.5 && second.relay_rtt_variation_ms == 42.5)
	client_bind_sent(&client, 7+64, time.tick_add(start, time.Second))
	client_bind_acknowledged(&client, 7, time.tick_add(start, 2*time.Second))
	testing.expect(t, stats(&client).relay_rtt_ms == second.relay_rtt_ms, "a reused ring slot cannot match an old nonce")
}

@(test)
client_stats_tcp_rtt_requires_an_outstanding_actually_sent_ping :: proc(t: ^testing.T) {
	start := time.tick_now()
	client: Client
	client_tcp_pong(&client, time.tick_add(start, 10*time.Millisecond))
	testing.expect(t, !stats(&client).has_relay_rtt)
	client.measurements.tcp_ping_pending = true
	client.measurements.tcp_ping_queued = start
	client_tcp_pong(&client, time.tick_add(start, 10*time.Millisecond))
	testing.expect(t, !stats(&client).has_relay_rtt && client.measurements.tcp_ping_pending, "queued but unsent pings have no wire RTT")
	client.transport.last_ping_sent = time.tick_add(start, -time.Millisecond)
	client_tcp_pong(&client, time.tick_add(start, 10*time.Millisecond))
	testing.expect(t, !stats(&client).has_relay_rtt, "a previous ping's timestamp cannot match the new outstanding ping")
	client.transport.last_ping_sent = time.tick_add(start, time.Millisecond)
	client_tcp_pong(&client, time.tick_add(start, 11*time.Millisecond))
	testing.expect(t, stats(&client).relay_rtt_ms == 10 && !client.measurements.tcp_ping_pending)
	client_tcp_pong(&client, time.tick_add(start, 30*time.Millisecond))
	testing.expect(t, stats(&client).relay_rtt_ms == 10)
}

@(test)
client_stats_udp_loss_waits_for_reordering_and_finalizes_only_missing_sequences :: proc(t: ^testing.T) {
	client: Client
	for sequence: u32 = 1; sequence <= 130; sequence += 1 {
		if sequence == 5 || sequence == 6 {continue}
		client_observe_udp(&client, sequence)
		if sequence == 63 {
			client_observe_udp(&client, 5) // Late, but still in the live window.
			testing.expect(t, stats(&client).udp_rx_expected == 0 && stats(&client).udp_rx_lost == 0,
				"pending gaps are not declared lost before leaving the reorder window")
		}
	}
	value := stats(&client)
	testing.expect(t, value.udp_rx_expected == 66 && value.udp_rx_received == 65 && value.udp_rx_lost == 1 && value.udp_reordered == 1)
	testing.expect(t, value.udp_rx_loss_percent > 1.51 && value.udp_rx_loss_percent < 1.52)
	client_observe_udp(&client, 130)
	client_observe_udp(&client, 6) // Outside the finalized window now.
	value = stats(&client)
	testing.expect(t, value.udp_duplicates == 1 && value.udp_invalid == 1 && value.udp_rx_lost == 1,
		"duplicates and too-late traffic remain separate from finalized loss")
	client = {}
	for index: u32 = 0; index < 101; index += 1 {
		if index == 5 {continue}
		client_observe_udp(&client, 0xffffffc0+index)
	}
	value = stats(&client)
	testing.expect(t, value.udp_rx_expected == 37 && value.udp_rx_received == 36 && value.udp_rx_lost == 1,
		"loss accounting remains consistent across datagram sequence wrap")
}

@(test)
client_stats_rolling_rates_expire_and_reuse_buckets_without_resetting_totals :: proc(t: ^testing.T) {
	start := time.tick_add(time.Tick{}, 100*time.Second)
	meter: Traffic_Meter
	traffic_record(&meter, {tx_bytes = 100, rx_bytes = 40, tx_packets = 2, rx_packets = 1}, start)
	traffic_record(&meter, {tx_bytes = 30, tx_packets = 1}, time.tick_add(start, 250*time.Millisecond))
	testing.expect_value(t, traffic_recent(&meter, time.tick_add(start, 990*time.Millisecond)).tx_bytes, u64(130))
	testing.expect_value(t, traffic_recent(&meter, time.tick_add(start, time.Second)).tx_bytes, u64(30))
	traffic_record(&meter, {tx_bytes = 200, tx_packets = 1}, time.tick_add(start, time.Second))
	testing.expect_value(t, traffic_recent(&meter, time.tick_add(start, time.Second)).tx_bytes, u64(230))
	testing.expect_value(t, meter.total.tx_bytes, u64(330))
	testing.expect_value(t, meter.total.tx_packets, u64(4))
	testing.expect(t, traffic_recent(&meter, time.tick_add(start, 3*time.Second)) == (Traffic_Counts{}))
	testing.expect_value(t, meter.total.rx_bytes, u64(40))
}

stats_test_consume_bytes :: proc(transport: ^Transport, count: int, now: time.Tick) -> u64 {
	completed := transport_count_sent_frames(transport, count, now)
	copy(transport.send_buffer[:transport.send_count-count], transport.send_buffer[count:transport.send_count])
	transport.send_count -= count
	return completed
}

@(test)
client_stats_tcp_packet_counts_survive_partial_headers_and_coalesced_writes :: proc(t: ^testing.T) {
	transport := Transport{open = true}
	assert(transport_queue(&transport, {kind = .Ping}))
	assert(transport_queue(&transport, {kind = .Data, payload_size = 3}))
	assert(transport_queue(&transport, {kind = .Data}))
	start := time.tick_now()
	testing.expect_value(t, stats_test_consume_bytes(&transport, 1, start), u64(0))
	testing.expect_value(t, stats_test_consume_bytes(&transport, 10, start), u64(0))
	testing.expect(t, transport.last_ping_sent == (time.Tick{}))
	ping_sent := time.tick_add(start, time.Millisecond)
	testing.expect_value(t, stats_test_consume_bytes(&transport, 2, ping_sent), u64(1))
	testing.expect(t, transport.last_ping_sent == ping_sent && transport.send_frame_remaining == 14)
	testing.expect_value(t, stats_test_consume_bytes(&transport, 5, start), u64(0))
	testing.expect_value(t, stats_test_consume_bytes(&transport, 21, start), u64(2))
	testing.expect(t, transport.send_count == 0 && transport.send_frame_remaining == 0,
		"only complete transmitted protocol frames count as packets")
}

@(test)
client_stats_tcp_socket_counters_and_single_outstanding_heartbeat :: proc(t: ^testing.T) {
	client, relay, connected := latency_test_client_pair()
	assert(connected)
	defer disconnect(&client)
	defer transport_close(&relay)
	client.last_ping = time.tick_add(time.tick_now(), -CLIENT_HEARTBEAT_INTERVAL)
	_, available, ok := poll(&client)
	assert(ok && !available)
	ping, received := latency_test_receive(&relay)
	assert(received && ping.kind == .Ping)
	client.last_ping = time.tick_add(time.tick_now(), -CLIENT_HEARTBEAT_INTERVAL)
	_, available, ok = poll(&client)
	assert(ok && !available && transport_receive(&relay))
	_, another, valid := transport_next(&relay)
	testing.expect(t, valid && !another, "a second ping cannot be queued before the first pong arrives")
	assert(transport_queue(&relay, {kind = .Pong}) && transport_flush(&relay))
	started := time.tick_now()
	for !stats(&client).has_relay_rtt && time.tick_since(started) < time.Second {_, _, ok = poll(&client); assert(ok); time.sleep(time.Millisecond)}
	value := stats(&client)
	testing.expect(t, value.has_relay_rtt && value.relay_rtt_ms > 0 && value.tx_bytes == FRAME_HEADER_SIZE && value.rx_bytes == FRAME_HEADER_SIZE &&
		value.tx_packets == 1 && value.rx_packets == 1, "socket counters include the actual heartbeat frames")
}

@(test)
client_stats_udp_socket_bytes_include_binding_and_keep_invalid_senders_out_of_loss :: proc(t: ^testing.T) {
	fixture: UDP_Test_Fixture
	defer udp_test_cleanup(&fixture)
	udp_test_start(&fixture)
	udp_test_negotiate_token(&fixture)
	udp_test_ack(&fixture)
	before := stats(&fixture.client)
	testing.expect(t, before.has_relay_rtt && before.relay_rtt_ms > 0 && before.tx_bytes >= FRAME_HEADER_SIZE+UDP_HEADER_SIZE && before.rx_packets >= 2,
		"TCP session control and authenticated UDP binding are measured")
	assert(send(&fixture.client, []u8{42}, 1))
	data, _ := udp_test_receive(fixture.socket)
	assert(data.kind == .Data)
	after := stats(&fixture.client)
	testing.expect(t, after.tx_bytes == before.tx_bytes+UDP_HEADER_SIZE+FRAME_HEADER_SIZE+1 && after.tx_packets == before.tx_packets+1,
		"only the successfully sent datagram contributes socket bytes")
	udp_test_expect_data(&fixture, 1)
	initial_window := fixture.client.measurements.udp_observed
	bad := UDP_Datagram{kind = .Data, token = fixture.token, sequence = 100000, packet = {kind = .Data, peer = fixture.client.peer_id}}
	udp_test_send(fixture.socket, fixture.client_endpoint, bad)
	udp_test_wait_rejected(&fixture.client, 1)
	after = stats(&fixture.client)
	testing.expect(t, fixture.client.measurements.udp_observed == initial_window && after.udp_invalid == 1 && after.udp_rx_expected == 0 && after.udp_rx_lost == 0,
		"an authenticated invalid sender cannot mint sequence gaps or inflate RX loss")
	udp_test_expect_data(&fixture, 2)
	testing.expect_value(t, stats(&fixture.client).udp_rx_lost, u64(0))
}

@(test)
client_stats_disconnect_preserves_lifetime_and_failed_connect_starts_fresh :: proc(t: ^testing.T) {
	client, relay, connected := latency_test_client_pair()
	assert(connected)
	defer disconnect(&client)
	defer transport_close(&relay)
	client.status, client.peer_id = .In_Room, 2
	assert(send(&client, []u8{1, 2, 3}, 1))
	traffic_record(&client.measurements.udp_traffic, {rx_bytes = 17, rx_packets = 1}, time.tick_now())
	client.measurements.tcp_rtt = {available = true, mean_ms = 42, variation_ms = 3}
	before := stats(&client)
	disconnect(&client)
	after := stats(&client)
	testing.expect(t, before.tx_bytes > 0 && after.tx_bytes == before.tx_bytes && after.rx_bytes == 17 && after.has_relay_rtt && after.relay_rtt_ms == 42,
		"closing sockets retains the connection's measurements")
	assert(connect(&client, "127.0.0.1:0") != nil)
	testing.expect(t, stats(&client) == (Client_Stats{}), "a failed new dial must not combine old TCP counters with fresh UDP counters")
	testing.expect(t, stats(nil) == (Client_Stats{}))
}
