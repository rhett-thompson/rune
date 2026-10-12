package main

import "core:fmt"
import "core:time"
import "rune:ecs"
import "rune:network"
import rl "vendor:raylib"

Game_Rates :: struct {
	started, ready: bool,
	last_sample: time.Tick,
	previous_inputs, previous_snapshots: u64,
	inputs_per_second, snapshots_per_second: f64,
}

game_rates_update :: proc(rates: ^Game_Rates, now: time.Tick, inputs, snapshots: u64) {
	if !rates.started || inputs < rates.previous_inputs || snapshots < rates.previous_snapshots {
		rates^ = {started=true, last_sample=now, previous_inputs=inputs, previous_snapshots=snapshots}
		return
	}
	elapsed := time.tick_diff(rates.last_sample, now)
	if elapsed < time.Second {return}
	seconds := f64(elapsed)/f64(time.Second)
	rates.inputs_per_second = f64(inputs-rates.previous_inputs)/seconds
	rates.snapshots_per_second = f64(snapshots-rates.previous_snapshots)/seconds
	rates.previous_inputs, rates.previous_snapshots = inputs, snapshots
	rates.last_sample, rates.ready = now, true
}

game_stats_update :: proc(state: ^Game_State, world: ^ecs.World, now: time.Tick) {
	if state.status != .Playing {return}
	remote_peer: u32
	if state.replica.count == 2 {remote_peer = state.guest_peer if state.hosting else u32(1)}
	if !peer_stats_update(&state.peer_stats, &state.client, remote_peer, now) {
		game_fail(state, world, "The connection could not send a ping probe.")
		return
	}
	inputs := state.inputs_received if state.hosting else state.inputs_sent
	snapshots := state.snapshots_sent if state.hosting else state.snapshots_received
	game_rates_update(&state.rates, now, inputs, snapshots)
}

stats_latency_label :: proc(available: bool, milliseconds: f64) -> string {
	if !available {return "--"}
	return fmt.tprintf("%.1f ms", milliseconds) if milliseconds < 100 else fmt.tprintf("%.0f ms", milliseconds)
}

stats_bandwidth_label :: proc(bytes_per_second: f64) -> string {
	if bytes_per_second >= 1024*1024 {return fmt.tprintf("%.1f MiB/s", bytes_per_second/(1024*1024))}
	return fmt.tprintf("%.1f KiB/s", bytes_per_second/1024)
}

game_stats_backlog :: proc(state: ^Game_State) -> int {
	return state.guest_inputs.count if state.hosting else state.prediction.pending.count
}

// Keep the panel in the unused header space: it never obscures player motion
// or the room controls. Fixed columns prevent proportional digits shifting rows.
draw_network_stats :: proc(state: ^Game_State) {
	stats := network.stats(&state.client)
	rl.DrawRectangleRounded({320, 18, 440, 82}, .12, 6, {18, 28, 43, 245})
	rl.DrawRectangleLinesEx({320, 18, 440, 82}, 1, {48, 64, 86, 255})
	draw_label("PING", 332, 23, 14, MUTED_COLOR)
	draw_label(stats_latency_label(state.peer_stats.has_rtt, state.peer_stats.rtt_ms), 374, 23, 14, TEXT_COLOR)
	draw_label("RELAY", 472, 23, 14, MUTED_COLOR)
	draw_label(stats_latency_label(stats.has_relay_rtt, stats.relay_rtt_ms), 524, 23, 14, TEXT_COLOR)
	draw_label(fmt.tprintf("FPS %d", rl.GetFPS()), 674, 23, 14, TEXT_COLOR)
	draw_label(fmt.tprintf("UP %s  %.0f p/s", stats_bandwidth_label(stats.tx_bytes_per_second), stats.tx_packets_per_second), 332, 42, 14, TEXT_COLOR)
	draw_label(fmt.tprintf("DOWN %s  %.0f p/s", stats_bandwidth_label(stats.rx_bytes_per_second), stats.rx_packets_per_second), 540, 42, 14, TEXT_COLOR)
	loss := fmt.tprintf("%.1f%%", stats.udp_rx_loss_percent) if state.client.udp_ready && stats.udp_rx_expected > 0 else "--"
	draw_label(fmt.tprintf("RX LOSS %s", loss), 332, 61, 14, TEXT_COLOR)
	draw_label(fmt.tprintf("RTT JITTER %s", stats_latency_label(state.peer_stats.has_rtt, state.peer_stats.jitter_ms)), 472, 61, 14, TEXT_COLOR)
	rates := fmt.tprintf("INPUT %.0f/s   STATE %.0f/s", state.rates.inputs_per_second, state.rates.snapshots_per_second) if state.rates.ready else "INPUT --   STATE --"
	draw_label(rates, 332, 80, 14, TEXT_COLOR)
	draw_label(fmt.tprintf("BACKLOG %d", game_stats_backlog(state)), 620, 80, 14, TEXT_COLOR)
}
