package main

import "core:testing"
import "core:time"
import relay "../../rune_relay/server"
import "rune:ecs"
import "rune:network"

@(test)
game_rate_samples_use_elapsed_time_and_reset_for_a_new_session :: proc(t: ^testing.T) {
	rates: Game_Rates
	start := time.tick_now()
	game_rates_update(&rates, start, 100, 30)
	game_rates_update(&rates, time.tick_add(start, time.Second/2), 130, 40)
	testing.expect(t, !rates.ready, "a partial startup interval does not report an invented full-second rate")
	game_rates_update(&rates, time.tick_add(start, time.Second), 160, 50)
	testing.expect(t, rates.ready && rates.inputs_per_second == 60 && rates.snapshots_per_second == 20)
	game_rates_update(&rates, time.tick_add(start, 5*time.Second/2), 250, 80)
	testing.expect(t, rates.inputs_per_second == 60 && rates.snapshots_per_second == 20,
		"a delayed stats update divides by the actual one-and-a-half-second interval")
	before := rates
	game_rates_update(&rates, start, 250, 80)
	testing.expect(t, rates == before, "an old timestamp cannot corrupt a measured rate")
	game_rates_update(&rates, time.tick_add(start, 3*time.Second), 0, 0)
	testing.expect(t, !rates.ready && rates.previous_inputs == 0 && rates.previous_snapshots == 0,
		"new session counters reset the sample instead of producing unsigned overflow")
}

@(test)
both_games_measure_peer_ping_without_changing_movement_or_snapshots :: proc(t: ^testing.T) {
	fixture: Game_Test_Fixture
	test_init_game(&fixture); defer test_destroy_game(&fixture)
	world := ecs.init(); defer ecs.destroy(&world)
	guest := Game_State{client=fixture.guest, local_peer=fixture.guest.peer_id, status=.Playing, started=time.tick_now()}
	fixture.guest = {}
	defer game_cleanup(&guest, &world)
	assert(game_send_snapshot(&fixture.host, &fixture.world))
	test_wait_guest(&fixture, &guest, &world, 1, 0)
	host_version, guest_version := ecs.change_version(&fixture.world), ecs.change_version(&world)
	snapshots_sent := fixture.host.snapshots_sent
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		assert(relay.server_update(&fixture.server))
		game_pump(&fixture.host, &fixture.world, &fixture.registry)
		game_pump(&guest, &world, &fixture.registry)
		game_stats_update(&fixture.host, &fixture.world, time.tick_now())
		game_stats_update(&guest, &world, time.tick_now())
		if fixture.host.peer_stats.has_rtt && guest.peer_stats.has_rtt &&
		   network.stats(&fixture.host.client).has_relay_rtt && network.stats(&guest.client).has_relay_rtt {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, fixture.host.peer_stats.has_rtt && guest.peer_stats.has_rtt,
		"both game windows measure their own authenticated peer round trip")
	testing.expect(t, network.stats(&fixture.host.client).has_relay_rtt && network.stats(&guest.client).has_relay_rtt,
		"TCP heartbeat measurements provide a separate relay round trip")
	testing.expect(t, fixture.host.inputs_received == 0 && fixture.host.guest_inputs.count == 0 && guest.prediction.pending.count == 0 &&
		fixture.host.snapshots_sent == snapshots_sent && guest.snapshots_received == 1 &&
		fixture.host.rejected_messages == 0 && guest.rejected_messages == 0,
		"ping packets do not count as movement inputs, scene snapshots, or malformed game data")
	testing.expect(t, ecs.change_version(&fixture.world) == host_version && ecs.change_version(&world) == guest_version,
		"network diagnostics leave both ECS simulations unchanged")
}
