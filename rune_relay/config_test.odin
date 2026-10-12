package main

import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

config_test_expect_options :: proc(t: ^testing.T, actual, expected: Relay_Options) {
	testing.expect_value(t, actual.server.listen.port, expected.server.listen.port)
	switch address in expected.server.listen.address {
	case net.IP4_Address:
		actual_address, ok := actual.server.listen.address.(net.IP4_Address)
		if testing.expect(t, ok) {testing.expect_value(t, actual_address, address)}
	case net.IP6_Address:
		actual_address, ok := actual.server.listen.address.(net.IP6_Address)
		if testing.expect(t, ok) {testing.expect_value(t, actual_address, address)}
	case:
		testing.expect(t, actual.server.listen.address == nil)
	}
	testing.expect_value(t, actual.server.max_connections, expected.server.max_connections)
	testing.expect_value(t, actual.server.max_rooms, expected.server.max_rooms)
	testing.expect_value(t, actual.server.idle_timeout, expected.server.idle_timeout)
	testing.expect_value(t, actual.server.packets_per_second, expected.server.packets_per_second)
	testing.expect_value(t, actual.server.udp_enabled, expected.server.udp_enabled)
	testing.expect_value(t, actual.server.udp_configured, expected.server.udp_configured)
	testing.expect_value(t, actual.run_duration, expected.run_duration)
}

// Each fixture has its own path so these tests do not change the process cwd
// or interfere with the optional configuration file beside a user's relay.
config_test_file :: proc(t: ^testing.T, contents: string, pattern := "rune-relay-config-*.json") -> string {
	file, error := os.create_temp_file("", pattern)
	if error != nil {testing.fail_now(t, "could not create temporary relay configuration")}
	path := strings.clone(os.name(file))
	written, write_error := os.write(file, transmute([]u8)contents)
	close_error := os.close(file)
	if written != len(contents) || write_error != nil || close_error != nil {
		os.remove(path)
		delete(path)
		testing.fail_now(t, "could not write temporary relay configuration")
	}
	return path
}

@(test)
relay_config_defaults_and_omitted_fields :: proc(t: ^testing.T) {
	defaults := default_options()
	testing.expect_value(t, defaults.server.max_connections, 128)
	testing.expect_value(t, defaults.server.max_rooms, 64)
	testing.expect_value(t, defaults.server.idle_timeout, 30 * time.Second)
	testing.expect_value(t, defaults.server.packets_per_second, 256)
	testing.expect(t, defaults.server.udp_enabled && defaults.server.udp_configured)
	testing.expect_value(t, defaults.run_duration, time.Duration(0))
	testing.expect_value(t, defaults.server.listen.port, 7777)
	address, valid := defaults.server.listen.address.(net.IP4_Address)
	if testing.expect(t, valid) {testing.expect_value(t, address, net.IP4_Loopback)}
	for fixture in ([]string{`{}`, `{"$schema":"./schemas/rune_relay.schema.json"}`}) {
		options := defaults
		testing.expect_value(t, parse_config_json(transmute([]u8)fixture, &options), "")
		config_test_expect_options(t, options, defaults)
	}
	options := defaults
	options.run_duration = 2 * time.Second
	options.server.packets_per_second = 80
	expected := options
	expected.server.max_connections = 512
	testing.expect_value(t, parse_config_json(transmute([]u8)string(`{"max_connections":512}`), &options), "")
	config_test_expect_options(t, options, expected)
}

@(test)
relay_config_valid_fields_and_boundaries :: proc(t: ^testing.T) {
	options := default_options()
	fixture := `{"listen":"[::1]:7788","max_connections":512,"max_rooms":200,"timeout_seconds":17,"packets_per_second":89,"run_seconds":1.25}`
	testing.expect_value(t, parse_config_json(transmute([]u8)fixture, &options), "")
	expected := default_options()
	expected.server.listen = {net.IP6_Loopback, 7788}
	expected.server.max_connections = 512
	expected.server.max_rooms = 200
	expected.server.idle_timeout = 17 * time.Second
	expected.server.packets_per_second = 89
	expected.run_duration = time.Second + time.Second / 4
	config_test_expect_options(t, options, expected)

	minimum := `{"listen":"0.0.0.0:0","max_connections":1,"max_rooms":1,"timeout_seconds":5,"packets_per_second":8,"run_seconds":0.5}`
	maximum := `{"listen":"127.0.0.1:65535","max_connections":4096,"max_rooms":4096,"timeout_seconds":3600,"packets_per_second":10000,"run_seconds":86400}`
	for boundary in ([]string{minimum, maximum}) {
		options = default_options()
		testing.expect_value(t, parse_config_json(transmute([]u8)boundary, &options), "")
	}
	// JSON numbers may use decimal or exponent spelling while still describing
	// an integer setting; validation concerns their value, not their spelling.
	integral_numbers := `{"max_connections":128.0,"max_rooms":1e2}`
	options = default_options()
	testing.expect_value(t, parse_config_json(transmute([]u8)integral_numbers, &options), "")
	testing.expect_value(t, options.server.max_connections, 128)
	testing.expect_value(t, options.server.max_rooms, 100)
	options = default_options()
	testing.expect_value(t, parse_config_json(transmute([]u8)maximum, &options), "")
	testing.expect_value(t, options.server.listen.port, 65535)
	testing.expect_value(t, options.server.max_connections, 4096)
	testing.expect_value(t, options.server.max_rooms, 4096)
	testing.expect_value(t, options.server.idle_timeout, 3600 * time.Second)
	testing.expect_value(t, options.server.packets_per_second, 10000)
	testing.expect_value(t, options.run_duration, 86400 * time.Second)
}

@(test)
relay_config_success_releases_parse_allocations :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	previous := context.allocator
	context.allocator = mem.tracking_allocator(&tracker)
	fixture := `{"$schema":"./schemas/rune_relay.schema.json","listen":"[::1]:7788","max_connections":512,"max_rooms":200,"timeout_seconds":17,"packets_per_second":89,"run_seconds":1.25}`
	succeeded := true
	options: Relay_Options
	for _ in 0..<3 {
		options = default_options()
		succeeded = succeeded && parse_config_json(transmute([]u8)fixture, &options) == ""
	}
	context.allocator = previous
	testing.expect(t, succeeded)
	testing.expect(t, tracker.total_allocation_count > 0)
	testing.expect_value(t, tracker.current_memory_allocated, i64(0))
	testing.expect_value(t, len(tracker.bad_free_array), 0)
	testing.expect_value(t, options.server.listen.port, 7788)
	testing.expect_value(t, options.server.max_connections, 512)
}

@(test)
relay_config_rejects_invalid_json_transactionally :: proc(t: ^testing.T) {
	// A preceding valid field must not be committed if a later field fails.
	fixtures := []string{
		``, `{`, `{"max_connections":128,}`, `{} {}`, `{} true`, `{} invalid`, `{} }`,
		`null`, `[]`, `"settings"`, `true`, `42`,
		`{"unknown":1}`, `{"":1}`, `{"$schema":42}`,
		`{"max_connections":128,"max_connections":256}`,
		`{"max_connections":128/* comment */}`, `// comment
{}`, `{'max_connections':128}`, `{max_connections:128}`,
		`{"listen":null}`, `{"listen":7777}`, `{"listen":{}}`,
		`{"listen":"localhost:7777"}`, `{"listen":"127.0.0.1"}`,
		`{"listen":"127.0.0.1:65536"}`, `{"listen":"127.0.0.1:-1"}`,
		`{"listen":"999.1.1.1:7777"}`, `{"listen":"::1:7777"}`,
		`{"max_connections":"128"}`, `{"max_connections":null}`, `{"max_connections":true}`,
		`{"max_connections":[]}`, `{"max_connections":1.5}`, `{"max_connections":0}`,
		`{"max_connections":-1}`, `{"max_connections":4097}`,
		`{"max_connections":18446744073709551616}`, `{"max_connections":18446744073709551744}`,
		`{"max_connections":1e9999}`,
		`{"max_rooms":0}`, `{"max_rooms":4097}`, `{"max_rooms":2.5}`, `{"max_rooms":true}`,
		`{"max_connections":32}`, `{"max_connections":100,"max_rooms":101}`,
		`{"timeout_seconds":4}`, `{"timeout_seconds":3601}`, `{"timeout_seconds":5.5}`,
		`{"timeout_seconds":"30"}`, `{"timeout_seconds":1e9999}`,
		`{"packets_per_second":7}`, `{"packets_per_second":10001}`,
		`{"packets_per_second":8.5}`, `{"packets_per_second":null}`,
		`{"run_seconds":0}`, `{"run_seconds":-1}`, `{"run_seconds":86400.1}`,
		`{"run_seconds":"1"}`, `{"run_seconds":true}`, `{"run_seconds":1e9999}`,
		`{"udp_enabled":"true"}`, `{"udp_enabled":1}`, `{"udp_enabled":null}`, `{"udp_enabled":{}}`,
		`{"listen":"0.0.0.0:8000","max_connections":4000,"max_rooms":4001}`,
	}
	for fixture in fixtures {
		options := default_options()
		options.run_duration = 3 * time.Second
		original := options
		testing.expect(t, parse_config_json(transmute([]u8)fixture, &options) != "", fixture)
		config_test_expect_options(t, options, original)
	}
}

@(test)
relay_config_file_load_and_cli_precedence :: proc(t: ^testing.T) {
	path := config_test_file(t, `{"listen":"0.0.0.0:8000","max_connections":256,"max_rooms":128,"timeout_seconds":45,"packets_per_second":100,"run_seconds":3.5}`)
	defer {os.remove(path); delete(path)}
	options, help, error := load_options([]string{"--config", path})
	testing.expect_value(t, error, "")
	testing.expect(t, !help)
	expected := default_options()
	expected.server.listen = {net.IP4_Address{0, 0, 0, 0}, 8000}
	expected.server.max_connections = 256
	expected.server.max_rooms = 128
	expected.server.idle_timeout = 45 * time.Second
	expected.server.packets_per_second = 100
	expected.run_duration = 3 * time.Second + time.Second / 2
	config_test_expect_options(t, options, expected)

	expected.server.listen = {net.IP6_Loopback, 9000}
	expected.server.max_connections = 64
	expected.server.max_rooms = 32
	expected.server.idle_timeout = 17 * time.Second
	expected.server.packets_per_second = 89
	expected.run_duration = time.Second + time.Second / 4
	for args in ([][]string{
		{"--config", path, "--listen", "[::1]:9000", "--max-connections", "64", "--max-rooms", "32", "--timeout-seconds", "17", "--packets-per-second", "89", "--run-seconds", "1.25"},
		{"--listen", "[::1]:9000", "--max-connections", "64", "--max-rooms", "32", "--timeout-seconds", "17", "--packets-per-second", "89", "--run-seconds", "1.25", "--config", path},
	}) {
		options, help, error = load_options(args)
		testing.expect_value(t, error, "")
		testing.expect(t, !help)
		config_test_expect_options(t, options, expected)
	}
}

@(test)
relay_config_explicit_file_errors_and_help_bypass :: proc(t: ^testing.T) {
	// Tests share an RNG seed, so another parallel fixture could recreate a
	// deleted filename when both use the same temporary-file pattern.
	missing_path := config_test_file(t, `{}`, "rune-relay-missing-*.json")
	defer delete(missing_path)
	if !testing.expect_value(t, os.remove(missing_path), nil) {return}
	invalid_path := config_test_file(t, `{"max_connections":4097}`)
	defer {os.remove(invalid_path); delete(invalid_path)}
	malformed_path := config_test_file(t, `{`)
	defer {os.remove(malformed_path); delete(malformed_path)}
	for path in ([]string{missing_path, invalid_path, malformed_path}) {
		_, help, error := load_options([]string{"--config", path})
		testing.expect(t, error != "", "explicit missing or invalid configuration must fail")
		testing.expect(t, !help)
		for args in ([][]string{{"--config", path, "--help"}, {"-h", "--config", path}}) {
			_, help, error = load_options(args)
			testing.expect_value(t, error, "")
			testing.expect(t, help, "help must not try to load configuration")
		}
	}
}

@(test)
relay_config_rejects_invalid_cli_options :: proc(t: ^testing.T) {
	path := config_test_file(t, `{}`)
	defer {os.remove(path); delete(path)}
	for args in ([][]string{
		{"--config"}, {"--config", path, "--unknown"},
		{"--config", path, "--listen"}, {"--config", path, "--listen", "localhost:7777"},
		{"--config", path, "--max-connections", "1.5"},
		{"--config", path, "--max-connections", "4097"},
		{"--config", path, "--max-connections", "32"},
		{"--config", path, "--max-rooms", "0"},
		{"--config", path, "--timeout-seconds", "4"},
		{"--config", path, "--packets-per-second", "10001"},
		{"--config", path, "--run-seconds", "0"},
		{"--config", path, "--run-seconds", "1e9999"},
		{"--config", path, "--run-seconds", "NaN"},
	}) {
		_, help, error := load_options(args)
		testing.expect(t, error != "", "invalid command-line option must fail")
		testing.expect(t, !help)
	}
}

@(test)
relay_config_udp_boolean_and_standalone_cli_precedence :: proc(t: ^testing.T) {
	path := config_test_file(t, `{"udp_enabled":false}`)
	defer {os.remove(path); delete(path)}
	for args in ([][]string{
		{"--config", path}, {"--no-udp", "--config", path},
		{"--config", path, "--udp", "--no-udp"},
	}) {
		options, help, error := load_options(args)
		testing.expect_value(t, error, "")
		testing.expect(t, !help && options.server.udp_configured && !options.server.udp_enabled)
	}
	for args in ([][]string{
		{"--udp", "--config", path}, {"--config", path, "--udp"},
		{"--no-udp", "--listen", "127.0.0.1:0", "--udp", "--config", path},
	}) {
		options, help, error := load_options(args)
		testing.expect_value(t, error, "")
		testing.expect(t, !help && options.server.udp_configured && options.server.udp_enabled)
	}
	options := default_options()
	testing.expect_value(t, parse_config_json(transmute([]u8)string(`{"udp_enabled":true}`), &options), "")
	testing.expect(t, options.server.udp_enabled && options.server.udp_configured)
	_, help, error := load_options([]string{"--no-udp", "--config", "does-not-exist.json", "--help"})
	testing.expect(t, help && error == "")
	_, help, error = load_options([]string{"--config", path, "--udp", "false"})
	testing.expect(t, !help && error != "", "standalone flags must reject an unexpected value")
}
