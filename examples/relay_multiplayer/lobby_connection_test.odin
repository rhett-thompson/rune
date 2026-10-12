package main

import "core:net"
import "core:sync"
import "core:testing"
import "core:time"
import relay "../../rune_relay/server"
import rune "rune:core"
import "rune:ecs"
import "rune:network"
import "rune:replication"
import "rune:ui"

Lobby_Test_Fixture :: struct {
	server: relay.Server,
	engine: rune.Engine,
	world, host_world: ecs.World,
	host: Game_State,
}

Lobby_Test_Condition :: enum {Local_Host, Local_Scene, Lobby_Error, Server_Empty}

lobby_test_init :: proc(fixture: ^Lobby_Test_Fixture) -> bool {
	for &pending in pending_connections {if pending.job.running {return false}}
	fixture.engine.registry = ecs.init_registry()
	fixture.world, fixture.host_world = ecs.init(), ecs.init()
	if !ecs.register_builtin_components(&fixture.engine.registry) || !replication.register(&fixture.engine.registry) {return false}
	if relay.server_start(&fixture.server, {listen = {net.IP4_Loopback, 0}, max_connections = 8, max_rooms = 4}) != "" {return false}
	options, game_state, lobby, pending_connections = {}, {}, {}, {}
	app_view, active_connection, direct_start, exit_code = .Lobby, -1, false, 0
	app_started = time.tick_now()
	// The production network callback needs no graphics window when the menu
	// context is uninitialized. This exercises its automatic failure recovery.
	return ui.text_field_set(&lobby.server_field, net.endpoint_to_string(fixture.server.endpoint))
}

lobby_test_cleanup :: proc(fixture: ^Lobby_Test_Fixture, t: ^testing.T) {
	return_to_menu(&fixture.world)
	for &pending in pending_connections {
		connection_cancel(&pending.job)
		if pending.job.running {
			testing.expect(t, connection_test_wait(&pending.job), "local dial must finish before the next lobby test")
			connection_shutdown(&pending.job)
		}
	}
	game_cleanup(&fixture.host, &fixture.host_world)
	relay.server_stop(&fixture.server)
	ecs.destroy(&fixture.world)
	ecs.destroy(&fixture.host_world)
	ecs.destroy_registry(&fixture.engine.registry)
	lobby, options = {}, {}
}

lobby_test_step :: proc(fixture: ^Lobby_Test_Fixture) -> bool {
	if !relay.server_update(&fixture.server) {return false}
	if fixture.host.client.transport.open {
		game_pump(&fixture.host, &fixture.host_world, &fixture.engine.registry)
		if fixture.host.status == .Failed {return false}
	}
	on_network(&fixture.engine, &fixture.world)
	return true
}

lobby_test_wait :: proc(fixture: ^Lobby_Test_Fixture, condition: Lobby_Test_Condition) -> bool {
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		if !lobby_test_step(fixture) {return false}
		switch condition {
		case .Local_Host:
			if app_view == .Arena && game_state.local_peer == 1 && game_state.replica.count == 1 {return true}
		case .Local_Scene:
			if app_view == .Arena && game_state.local_peer != 0 && game_state.replica.count == 2 {return true}
		case .Lobby_Error:
			if app_view == .Lobby && !lobby.busy && lobby.error != "" {return true}
		case .Server_Empty:
			if fixture.server.stats.connections == 0 && fixture.server.stats.rooms == 0 {return true}
		}
		time.sleep(time.Millisecond)
	}
	return false
}

lobby_test_start_external_host :: proc(fixture: ^Lobby_Test_Fixture) -> bool {
	fixture.host = {hosting = true, started = time.tick_now(), status = .Waiting}
	if network.connect(&fixture.host.client, net.endpoint_to_string(fixture.server.endpoint)) != nil {return false}
	if !network.create_room(&fixture.host.client, 2) {return false}
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		if !lobby_test_step(fixture) {return false}
		if fixture.host.local_peer == 1 && fixture.host.replica.count == 1 {return true}
		time.sleep(time.Millisecond)
	}
	return false
}

@(test)
menu_udp_connection_transfers_both_sockets_and_negotiates :: proc(t: ^testing.T) {
	sync.mutex_lock(&menu_test_mutex); defer sync.mutex_unlock(&menu_test_mutex)
	fixture: Lobby_Test_Fixture
	if !testing.expect(t, lobby_test_init(&fixture)) {return}
	defer lobby_test_cleanup(&fixture, t)
	options.use_udp = true
	start_menu_connection(&fixture.world, true)
	if !testing.expect(t, lobby_test_wait(&fixture, .Local_Host)) {return}
	started := time.tick_now()
	for !game_state.client.udp_ready && time.tick_since(started) < 5*time.Second {
		if !testing.expect(t, lobby_test_step(&fixture)) {return}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, game_state.client.udp_requested && game_state.client.udp_open && game_state.client.udp_ready &&
		game_state.client.transport.open && game_state.status == .Playing,
		"the menu connection worker transfers both sockets and the normal frame pump completes UDP negotiation")
	return_to_menu(&fixture.world)
	testing.expect(t, lobby_test_wait(&fixture, .Server_Empty), "leaving the menu-created UDP room releases relay membership")
	testing.expect(t, !game_state.client.udp_open && !game_state.client.transport.open && fixture.server.stats.rooms == 0)
}

@(test)
lobby_host_creates_a_room_and_leaving_clears_the_client_and_scene :: proc(t: ^testing.T) {
	sync.mutex_lock(&menu_test_mutex); defer sync.mutex_unlock(&menu_test_mutex)
	fixture: Lobby_Test_Fixture
	if !testing.expect(t, lobby_test_init(&fixture)) {return}
	defer lobby_test_cleanup(&fixture, t)
	start_menu_connection(&fixture.world, true)
	testing.expect(t, lobby.busy && active_connection >= 0 && app_view == .Lobby)
	if !testing.expect(t, lobby_test_wait(&fixture, .Local_Host)) {return}
	testing.expect(t, game_state.hosting && game_state.client.is_host)
	testing.expect(t, network.room_code_valid(game_state.room_code[:]))
	testing.expect_value(t, fixture.server.stats.rooms, 1)
	return_to_menu(&fixture.world)
	testing.expect(t, app_view == .Lobby && !lobby.busy && active_connection == -1)
	testing.expect(t, !game_state.client.transport.open && game_state.local_peer == 0 && game_state.room_code == [16]u8{})
	testing.expect_value(t, game_state.replica.count, 0)
	remaining, valid := replication.snapshot_from_world(&fixture.world, 1)
	testing.expect(t, valid && remaining.count == 0)
	testing.expect(t, lobby_test_wait(&fixture, .Server_Empty), "leaving the host must close its room on the relay")
}

@(test)
lobby_join_accepts_a_lowercase_pasted_code_and_receives_the_hosts_scene :: proc(t: ^testing.T) {
	sync.mutex_lock(&menu_test_mutex); defer sync.mutex_unlock(&menu_test_mutex)
	fixture: Lobby_Test_Fixture
	if !testing.expect(t, lobby_test_init(&fixture)) {return}
	defer lobby_test_cleanup(&fixture, t)
	if !testing.expect(t, lobby_test_start_external_host(&fixture)) {return}
	lowercase := fixture.host.room_code
	for &character in lowercase {if character >= 'A' && character <= 'F' {character += 'a' - 'A'}}
	paste: [20]u8
	paste[0], paste[1] = ' ', '\t'
	copy(paste[2:18], lowercase[:])
	paste[18], paste[19] = '\r', '\n'
	testing.expect(t, menu_paste_code(&lobby, string(paste[:])))
	start_menu_connection(&fixture.world, false)
	if !testing.expect(t, lobby_test_wait(&fixture, .Local_Scene)) {return}
	testing.expect(t, !game_state.hosting && game_state.local_peer == 2 && !game_state.client.is_host)
	testing.expect_value(t, game_state.room_code, fixture.host.room_code)
	testing.expect(t, game_state.snapshots_received > 0 && fixture.host.guest_peer == 2 && fixture.host.replica.count == 2)
	return_to_menu(&fixture.world)
	started := time.tick_now()
	for fixture.host.guest_peer != 0 && time.tick_since(started) < 5*time.Second {
		if !testing.expect(t, lobby_test_step(&fixture)) {return}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, fixture.host.guest_peer == 0 && fixture.host.replica.count == 1)
	testing.expect_value(t, fixture.server.stats.rooms, 1)
}

@(test)
lobby_wrong_code_returns_an_error_and_can_retry_as_host :: proc(t: ^testing.T) {
	sync.mutex_lock(&menu_test_mutex); defer sync.mutex_unlock(&menu_test_mutex)
	fixture: Lobby_Test_Fixture
	if !testing.expect(t, lobby_test_init(&fixture)) {return}
	defer lobby_test_cleanup(&fixture, t)
	testing.expect(t, ui.text_field_set(&lobby.code_field, "0123456789abcdef"))
	start_menu_connection(&fixture.world, false)
	if !testing.expect(t, lobby_test_wait(&fixture, .Lobby_Error)) {return}
	testing.expect_value(t, lobby.error, "No room was found for that code. Check it and try again.")
	testing.expect(t, !game_state.client.transport.open && game_state.local_peer == 0 && game_state.replica.count == 0)
	testing.expect_value(t, exit_code, 0)
	start_menu_connection(&fixture.world, true)
	testing.expect(t, lobby.busy && lobby.error == "")
	testing.expect(t, lobby_test_wait(&fixture, .Local_Host))
}

@(test)
lobby_cancel_ignores_a_late_connection_and_can_immediately_retry :: proc(t: ^testing.T) {
	sync.mutex_lock(&menu_test_mutex); defer sync.mutex_unlock(&menu_test_mutex)
	fixture: Lobby_Test_Fixture
	if !testing.expect(t, lobby_test_init(&fixture)) {return}
	defer lobby_test_cleanup(&fixture, t)
	start_menu_connection(&fixture.world, true)
	first := active_connection
	if !testing.expect(t, first >= 0 && lobby.busy) {return}
	// Cancel before the result is collected, even if the loopback worker has
	// already finished. It must never enqueue a Create request or enter Arena.
	return_to_menu(&fixture.world)
	testing.expect(t, app_view == .Lobby && !lobby.busy && pending_connections[first].job.cancelled)
	if !testing.expect(t, connection_test_wait(&pending_connections[first].job)) {return}
	start_menu_connection(&fixture.world, true)
	testing.expect(t, active_connection >= 0 && active_connection != first && lobby.busy)
	if !testing.expect(t, lobby_test_wait(&fixture, .Local_Host)) {return}
	testing.expect(t, !pending_connections[first].job.running)
	testing.expect_value(t, fixture.server.stats.rooms, 1)
	testing.expect(t, game_state.hosting && game_state.local_peer == 1 && game_state.replica.count == 1)
}
