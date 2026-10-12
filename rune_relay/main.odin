package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:time"
import relay "./server"

print_help :: proc() {
	fmt.println("Rune relay server (TCP control, optional UDP realtime data)")
	fmt.println("Usage: rune_relay [options]")
	fmt.println("  --config <path>             JSON config; default rune_relay.json in the working directory if present")
	fmt.println("  --listen <IP:port>           Numeric endpoint; default 127.0.0.1:7777")
	fmt.println("  --max-connections <number>   1..4096; default 128")
	fmt.println("  --max-rooms <number>         1..4096; default 64")
	fmt.println("  --timeout-seconds <number>   Idle timeout, 5..3600; default 30")
	fmt.println("  --packets-per-second <number> Per-connection limit, 8..10000; default 256")
	fmt.println("  --udp / --no-udp             Enable or disable negotiated UDP data; default enabled")
	fmt.println("  --run-seconds <number>       Stop after this duration, greater than 0 and at most 86400")
	fmt.println("  --help                      Show this help")
	fmt.println("Command-line settings override the JSON config regardless of argument order.")
	fmt.println("IPv6 endpoints use brackets, for example [::1]:7777. Port 0 chooses a free port.")
}

print_stats :: proc(server: ^relay.Server) {
	stats := server.stats
	fmt.printf(
		"connections=%d rooms=%d accepted=%d forwarded=%d rejected=%d disconnected=%d udp_received=%d udp_forwarded=%d udp_rejected=%d udp_dropped=%d\n",
		stats.connections,
		stats.rooms,
		stats.accepted,
		stats.forwarded,
		stats.rejected,
		stats.disconnected,
		stats.udp_received,
		stats.udp_forwarded,
		stats.udp_rejected,
		stats.udp_dropped,
	)
}

run :: proc() -> int {
	options, show_help, config_error := load_options(os.args[1:])
	if show_help {print_help(); return 0}
	if config_error != "" {fmt.eprintln(config_error); return 2}
	server: relay.Server
	if error := relay.server_start(&server, options.server); error != "" {
		fmt.eprintln("Could not start relay:", error)
		return 1
	}
	defer relay.server_stop(&server)
	timer_enabled := relay_timer_begin()
	defer relay_timer_end(timer_enabled)
	fmt.printf("Rune relay listening on %s (TCP)\n", net.endpoint_to_string(server.endpoint))
	if server.udp_open {fmt.printf("Rune relay UDP enabled on %s\n", net.endpoint_to_string(server.endpoint))}
	started := time.tick_now()
	last_stats := started
	for {
		if !relay.server_update(&server) {fmt.eprintln("Relay listener failed"); return 1}
		if options.run_duration > 0 && time.tick_since(started) >= options.run_duration {break}
		if time.tick_since(last_stats) >= 10 * time.Second {
			print_stats(&server)
			last_stats = time.tick_now()
		}
		time.sleep(2 * time.Millisecond)
	}
	print_stats(&server)
	return 0
}

main :: proc() {
	exit_code := run()
	if exit_code != 0 {os.exit(exit_code)}
}
