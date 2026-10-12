package main

import "core:mem"
import "core:strings"
import "core:testing"

relay_test_argument_index :: proc(command: []string, argument: string) -> int {
	for value, index in command {if value == argument {return index}}
	return -1
}

relay_test_expect_option :: proc(t: ^testing.T, command: []string, option, value: string) {
	index := relay_test_argument_index(command, option)
	if !testing.expect(t, index >= 0 && index + 1 < len(command), option) {return}
	testing.expect_value(t, command[index + 1], value)
}

@(test)
relay_startup_banner_requires_a_complete_authentic_loopback_line :: proc(t: ^testing.T) {
	Fixture :: struct {text, endpoint: string}
	for fixture in ([]Fixture{
		{"Rune relay listening on 127.0.0.1:1 (TCP)\n", "127.0.0.1:1"},
		{"Rune relay listening on 127.0.0.1:65535 (TCP)\r\n", "127.0.0.1:65535"},
		{"compiler output\nRune relay listening on 127.0.0.1:49231 (TCP)\nconnections=0 rooms=0\n", "127.0.0.1:49231"},
	}) {
		endpoint, ready := relay_endpoint_from_log(fixture.text)
		if testing.expect(t, ready, fixture.text) {
			testing.expect_value(t, endpoint, fixture.endpoint)
			start := strings.index(fixture.text, fixture.endpoint)
			testing.expect(t, raw_data(endpoint) == raw_data(fixture.text[start:]), "endpoint must borrow the original log storage")
		}
	}
	for text in ([]string{
		"", "Rune relay listening on ",
		"Rune relay listening on 127.0.0.1:7777 (TCP)",
		"Rune relay listening on 127.0.0.1:7777 (TCP)\r",
		"Rune relay listening on 127.0.0.1:7777 (TC\n",
		"debug: Rune relay listening on 127.0.0.1:7777 (TCP)\n",
		" Rune relay listening on 127.0.0.1:7777 (TCP)\n",
		"Rune relay listening on 127.0.0.1:7777 (TCP) trailing\n",
		"Rune relay listening on 127.0.0.1:0 (TCP)\n",
		"Rune relay listening on 127.0.0.1:65536 (TCP)\n",
		"Rune relay listening on 127.0.0.1:999999999999999999999999 (TCP)\n",
		"Rune relay listening on 127.0.0.1:-1 (TCP)\n",
		"Rune relay listening on 127.0.0.1:77x7 (TCP)\n",
		"Rune relay listening on 127.0.0.1: (TCP)\n",
		"Rune relay listening on 127.0.0.1:7777junk (TCP)\n",
		"Rune relay listening on 0.0.0.0:7777 (TCP)\n",
		"Rune relay listening on 127.0.0.2:7777 (TCP)\n",
		"Rune relay listening on localhost:7777 (TCP)\n",
		"Rune relay listening on [::1]:7777 (TCP)\n",
	}) {
		_, ready := relay_endpoint_from_log(text)
		testing.expect(t, !ready, text)
	}
}

@(test)
relay_host_room_requires_a_complete_authenticated_host_line :: proc(t: ^testing.T) {
	for text in ([]string{
		"Room: 0123456789ABCDEF peer=1 role=host\n",
		"Room: 0123456789ABCDEF peer=1 role=host\r\n",
		"other output\nRoom: 0123456789ABCDEF peer=1 role=host\npositions follow\n",
	}) {
		room, ready := relay_room_from_log(text)
		if testing.expect(t, ready, text) {
			testing.expect_value(t, room, "0123456789ABCDEF")
			start := strings.index(text, "0123456789ABCDEF")
			testing.expect(t, raw_data(room) == raw_data(text[start:]), "room code must borrow the original log storage")
		}
	}
	for text in ([]string{
		"", "Room: 0123456789",
		"Room: 0123456789ABCDEF peer=1 role=host",
		"Room: 0123456789ABCDEF peer=1 role=host\r",
		"Room: 0123456789ABCDEF peer=1 role=hos\n",
		"debug: Room: 0123456789ABCDEF peer=1 role=host\n",
		" Room: 0123456789ABCDEF peer=1 role=host\n",
		"Room: 0123456789ABCDEF peer=1 role=host trailing\n",
		"Room: 0123456789ABCDE peer=1 role=host\n",
		"Room: 0123456789ABCDEF0 peer=1 role=host\n",
		"Room: 0123456789abcDEF peer=1 role=host\n",
		"Room: 0123456789ABCDEG peer=1 role=host\n",
		"Room: 0123456789ABCDEF peer=2 role=host\n",
		"Room: 0123456789ABCDEF peer=1 role=guest\n",
		"Room: 0123456789ABCDEF peer=1\n",
		"Room: 0123456789ABCDEF role=host\n",
	}) {
		_, ready := relay_room_from_log(text)
		testing.expect(t, !ready, text)
	}
}

@(test)
relay_readiness_ignores_spoofed_lines_before_the_real_banner :: proc(t: ^testing.T) {
	log := "debug: Rune relay listening on 127.0.0.1:1234 (TCP)\n" +
		"Rune relay listening on 127.0.0.1:51234 (TCP)\n" +
		"Room: 1111111111111111 peer=2 role=host\n" +
		"Room: ABCDEF0123456789 peer=1 role=host\n" +
		"partial next line"
	endpoint, listening := relay_endpoint_from_log(log)
	room, joined := relay_room_from_log(log)
	testing.expect(t, listening && joined)
	testing.expect_value(t, endpoint, "127.0.0.1:51234")
	testing.expect_value(t, room, "ABCDEF0123456789")
}

@(test)
relay_build_commands_keep_game_collections_out_of_the_core_server :: proc(t: ^testing.T) {
	suffix :: ".exe" when ODIN_OS == .Windows else ""
	collections := []Collection{{name = "r3d", path = "third_party/custom r3d"}}
	server := relay_build_command("rune_relay", "build/rune_relay" + suffix, nil)
	defer free_example_args(server)
	client := relay_build_command("examples/relay_multiplayer", "build/relay_multiplayer" + suffix, collections)
	defer free_example_args(client)
	for command in ([][]string{server[:], client[:]}) {
		if !testing.expect(t, len(command) >= 5) {continue}
		testing.expect_value(t, command[0], "odin")
		testing.expect_value(t, command[1], "build")
		testing.expect(t, relay_test_argument_index(command, "-o:none") >= 0)
		testing.expect(t, relay_test_argument_index(command, "-collection:rune=rune") >= 0)
		when ODIN_OS == .Windows {
			testing.expect(t, relay_test_argument_index(command, "-linker:msvc") >= 0)
		} else {
			testing.expect(t, relay_test_argument_index(command, "-linker:msvc") < 0)
		}
	}
	testing.expect_value(t, server[2], "rune_relay")
	testing.expect_value(t, client[2], "examples/relay_multiplayer")
	testing.expect(t, relay_test_argument_index(server[:], "-out:build/rune_relay" + suffix) >= 0)
	testing.expect(t, relay_test_argument_index(client[:], "-out:build/relay_multiplayer" + suffix) >= 0)
	testing.expect(t, relay_test_argument_index(server[:], "-collection:r3d=third_party/custom r3d") < 0)
	testing.expect(t, relay_test_argument_index(client[:], "-collection:r3d=third_party/custom r3d") >= 0)
	for argument in server {
		testing.expect(t, !strings.has_prefix(argument, "-collection:r3d="))
		testing.expect(t, !strings.has_prefix(argument, "--console-dir="))
	}
}

@(test)
relay_client_commands_preserve_player_roles_and_argument_boundaries :: proc(t: ^testing.T) {
	example := Example{path = "relay_multiplayer"}
	endpoint := "127.0.0.1:51234"
	room := "ABCDEF0123456789"
	args := []string{"--run-seconds", "0.25", "two words", "", "$HOME;touch", `C:\game\save`}
	host := relay_client_command(example, endpoint, "", args)
	defer free_example_args(host)
	guest := relay_client_command(example, endpoint, room, args)
	defer free_example_args(guest)
	suffix :: ".exe" when ODIN_OS == .Windows else ""
	for command in ([][]string{host[:], guest[:]}) {
		testing.expect_value(t, command[0], "./build/relay_multiplayer" + suffix)
		relay_test_expect_option(t, command, "--server", endpoint)
		for argument, index in args {testing.expect_value(t, command[len(command) - len(args) + index], argument)}
		testing.expect(t, relay_test_argument_index(command, "odin") < 0)
		testing.expect(t, relay_test_argument_index(command, "--") < 0)
	}
	testing.expect_value(t, len(host), 4 + len(args))
	testing.expect_value(t, len(guest), 5 + len(args))
	testing.expect(t, relay_test_argument_index(host[:], "--host") >= 0)
	testing.expect(t, relay_test_argument_index(host[:], "--join") < 0)
	testing.expect(t, relay_test_argument_index(guest[:], "--host") < 0)
	relay_test_expect_option(t, guest[:], "--join", room)
}

@(test)
relay_clients_write_console_logs_to_distinct_role_directories :: proc(t: ^testing.T) {
	example := Example{path = "relay_multiplayer"}
	args := []string{"--console-dir=build/console space", "--run-seconds", "0.25", "argument with spaces"}
	host := relay_client_command(example, "127.0.0.1:51234", "", args)
	defer free_example_args(host)
	guest := relay_client_command(example, "127.0.0.1:51234", "ABCDEF0123456789", args)
	defer free_example_args(guest)
	testing.expect(t, relay_test_argument_index(host[:], "--console-dir=build/console space/relay-host") >= 0)
	testing.expect(t, relay_test_argument_index(guest[:], "--console-dir=build/console space/relay-guest") >= 0)
	for command in ([][]string{host[:], guest[:]}) {
		testing.expect(t, relay_test_argument_index(command, args[0]) < 0)
		for argument, index in args[1:] {testing.expect_value(t, command[len(command) - len(args) + 1 + index], argument)}
	}
	testing.expect_value(t, args[0], "--console-dir=build/console space")
}

@(test)
relay_commands_own_their_strings_and_release_the_selected_allocator :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)
	package_path := strings.clone("examples/relay_multiplayer")
	defer delete(package_path)
	argument := strings.clone("two words")
	defer delete(argument)
	build := relay_build_command(package_path, "build/relay multiplayer", nil, allocator)
	client := relay_client_command(Example{path = "relay_multiplayer"}, "127.0.0.1:51234", "", {argument}, allocator)
	testing.expect(t, raw_data(build[2]) != raw_data(package_path), "build command must own the package path")
	testing.expect(t, raw_data(client[len(client) - 1]) != raw_data(argument), "client command must own forwarded arguments")
	package_bytes := transmute([]u8)package_path
	argument_bytes := transmute([]u8)argument
	package_bytes[0] = 'X'
	argument_bytes[0] = 'X'
	testing.expect_value(t, build[2], "examples/relay_multiplayer")
	testing.expect_value(t, client[len(client) - 1], "two words")
	free_example_args(client, allocator)
	free_example_args(build, allocator)
	testing.expect(t, tracker.total_allocation_count > 0)
	testing.expect_value(t, tracker.current_memory_allocated, i64(0))
	testing.expect_value(t, len(tracker.bad_free_array), 0)
}

@(test)
relay_managed_role_and_endpoint_flags_fail_before_starting_processes :: proc(t: ^testing.T) {
	example := Example{path = "relay-session-test-missing-example"}
	for flag in ([]string{"--host", "--join", "--server", "--capture"}) {
		code, error := run_relay_session(example, true, {"--run-seconds", "0.25", flag})
		testing.expect(t, code != 0, flag)
		testing.expect(t, strings.contains(error, flag), "managed arguments must report their own preflight rejection")
	}
}
