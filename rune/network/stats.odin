package network

import "core:math"
import "core:time"

// Counts protocol bytes, TCP frames and UDP datagrams, including control
// traffic. IP, UDP/TCP and link-layer headers are outside these measurements.
// Rates use a rolling second in 64 bounded buckets (15.625 ms granularity).
Client_Stats :: struct {
	has_relay_rtt: bool,
	relay_rtt_ms, relay_rtt_variation_ms: f64,
	tx_bytes, rx_bytes, tx_packets, rx_packets: u64,
	tx_bytes_per_second, rx_bytes_per_second, tx_packets_per_second, rx_packets_per_second: f64,
	udp_rx_expected, udp_rx_received, udp_rx_lost: u64,
	udp_rx_loss_percent: f64,
	udp_duplicates, udp_reordered, udp_invalid, udp_local_dropped: u64,
}

@(private="package")
Traffic_Counts :: struct {tx_bytes, rx_bytes, tx_packets, rx_packets: u64}
@(private="package")
Traffic_Bucket :: struct {interval: i64, counts: Traffic_Counts}
@(private="package")
Traffic_Meter :: struct {total: Traffic_Counts, buckets: [64]Traffic_Bucket}
@(private="package")
RTT_Estimate :: struct {available: bool, mean_ms, variation_ms: f64}
@(private="package")
Bind_Probe :: struct {sequence: u32, sent: time.Tick, pending: bool}
@(private="package")
Client_Measurements :: struct {
	udp_traffic: Traffic_Meter,
	tcp_rtt, udp_rtt: RTT_Estimate,
	tcp_ping_pending: bool,
	tcp_ping_queued: time.Tick,
	bind_probes: [64]Bind_Probe,
	udp_observed: Replay_Window,
	udp_duplicates, udp_reordered, udp_invalid: u64,
}

@(private="package")
traffic_add :: proc(target: ^Traffic_Counts, value: Traffic_Counts) {
	target.tx_bytes += value.tx_bytes
	target.rx_bytes += value.rx_bytes
	target.tx_packets += value.tx_packets
	target.rx_packets += value.rx_packets
}

@(private="package")
traffic_record :: proc(meter: ^Traffic_Meter, value: Traffic_Counts, now: time.Tick) {
	traffic_add(&meter.total, value)
	nanoseconds := i64(time.tick_diff({}, now))
	if nanoseconds < 0 {return}
	interval := nanoseconds / i64(time.Second/64)
	bucket := &meter.buckets[interval%64]
	if bucket.interval != interval {bucket^ = {interval = interval}}
	traffic_add(&bucket.counts, value)
}

@(private="package")
traffic_recent :: proc(meter: ^Traffic_Meter, now: time.Tick) -> Traffic_Counts {
	nanoseconds := i64(time.tick_diff({}, now))
	if nanoseconds < 0 {return {}}
	interval := nanoseconds / i64(time.Second/64)
	result: Traffic_Counts
	for bucket in meter.buckets {
		if bucket.interval <= interval && interval-bucket.interval < 64 {traffic_add(&result, bucket.counts)}
	}
	return result
}

@(private="package")
rtt_sample :: proc(estimate: ^RTT_Estimate, sent, received: time.Tick) {
	duration := time.tick_diff(sent, received)
	if duration <= 0 || duration > CLIENT_TIMEOUT {return}
	sample := f64(duration) / f64(time.Millisecond)
	if !estimate.available {
		estimate^ = {available = true, mean_ms = sample, variation_ms = sample/2}
	} else {
		estimate.variation_ms = .75*estimate.variation_ms + .25*math.abs(estimate.mean_ms-sample)
		estimate.mean_ms = .875*estimate.mean_ms + .125*sample
	}
}

@(private="package")
client_bind_sent :: proc(client: ^Client, sequence: u32, sent: time.Tick) {
	client.measurements.bind_probes[sequence%64] = {sequence = sequence, sent = sent, pending = true}
}

@(private="package")
client_bind_acknowledged :: proc(client: ^Client, sequence: u32, received: time.Tick) {
	probe := &client.measurements.bind_probes[sequence%64]
	if !probe.pending || probe.sequence != sequence {return}
	rtt_sample(&client.measurements.udp_rtt, probe.sent, received)
	probe.pending = false
}

@(private="package")
client_tcp_pong :: proc(client: ^Client, received: time.Tick) {
	measurements := &client.measurements
	if !measurements.tcp_ping_pending || client.transport.last_ping_sent == (time.Tick{}) ||
	   time.tick_diff(measurements.tcp_ping_queued, client.transport.last_ping_sent) < 0 {return}
	rtt_sample(&measurements.tcp_rtt, client.transport.last_ping_sent, received)
	measurements.tcp_ping_pending = false
}

@(private="package")
client_observe_udp :: proc(client: ^Client, sequence: u32) {
	window := &client.measurements.udp_observed
	before := window^
	if udp_replay_accept(window, sequence) {
		if before.has_latest && sequence != before.latest && i32(sequence-before.latest) <= 0 {client.measurements.udp_reordered += 1}
	} else {
		age := before.latest-sequence
		if before.has_latest && age < 64 && before.bits & (u64(1)<<age) != 0 {
			client.measurements.udp_duplicates += 1
		} else {
			client.measurements.udp_invalid += 1
		}
	}
}

// Snapshot without allocation or state changes. Loss is relay-to-client UDP
// Data only, finalized when a gap leaves the 64-datagram reorder window. A late
// datagram within that window fills its gap; invalid/duplicate traffic is not loss.
// Disconnect preserves measurements; the next connect starts a fresh lifetime.
stats :: proc(client: ^Client) -> Client_Stats {
	if client == nil {return {}}
	now := time.tick_now()
	total := client.transport.traffic.total
	traffic_add(&total, client.measurements.udp_traffic.total)
	recent := traffic_recent(&client.transport.traffic, now)
	traffic_add(&recent, traffic_recent(&client.measurements.udp_traffic, now))
	estimate := client.measurements.udp_rtt if client.udp_requested && client.measurements.udp_rtt.available else client.measurements.tcp_rtt
	window := client.measurements.udp_observed
	result := Client_Stats{
		has_relay_rtt = estimate.available, relay_rtt_ms = estimate.mean_ms, relay_rtt_variation_ms = estimate.variation_ms,
		tx_bytes = total.tx_bytes, rx_bytes = total.rx_bytes, tx_packets = total.tx_packets, rx_packets = total.rx_packets,
		tx_bytes_per_second = f64(recent.tx_bytes), rx_bytes_per_second = f64(recent.rx_bytes),
		tx_packets_per_second = f64(recent.tx_packets), rx_packets_per_second = f64(recent.rx_packets),
		udp_rx_expected = window.finalized_expected, udp_rx_received = window.finalized_received, udp_rx_lost = window.finalized_lost,
		udp_duplicates = client.measurements.udp_duplicates, udp_reordered = client.measurements.udp_reordered,
		udp_invalid = client.measurements.udp_invalid, udp_local_dropped = client.udp_dropped,
	}
	if window.finalized_expected > 0 {result.udp_rx_loss_percent = 100*f64(window.finalized_lost)/f64(window.finalized_expected)}
	return result
}
