package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import relay "./server"

DEFAULT_CONFIG_PATH :: "rune_relay.json"

Relay_Options :: struct {
	server:       relay.Server_Config,
	run_duration: time.Duration,
}

default_options :: proc() -> Relay_Options {
	listen, _ := net.parse_endpoint("127.0.0.1:7777")
	return {server = {
		listen = listen,
		max_connections = 128,
		max_rooms = 64,
		idle_timeout = 30 * time.Second,
		packets_per_second = 256,
		udp_enabled = true,
		udp_configured = true,
	}}
}

parse_listen :: proc(value: string) -> (net.Endpoint, bool) {
	separator := strings.last_index(value, ":")
	if separator <= 0 || separator + 1 >= len(value) {return {}, false}
	if value[0] == '[' {
		if separator < 3 || value[separator - 1] != ']' {return {}, false}
	} else if strings.count(value, ":") != 1 {
		return {}, false
	}
	endpoint, ok := net.parse_endpoint(value)
	return endpoint, ok && endpoint.port >= 0 && endpoint.port <= 65535
}

@(private="file")
integer_bounds :: proc(key: string) -> (int, int) {
	switch key {
	case "timeout_seconds": return 5, 3600
	case "packets_per_second": return 8, 10000
	}
	return 1, 4096
}

@(private="file")
set_integer_option :: proc(options: ^Relay_Options, key: string, number: int) -> string {
	minimum, maximum := integer_bounds(key)
	if number < minimum || number > maximum {
		return fmt.tprintf("%s must be between %d and %d", key, minimum, maximum)
	}
	switch key {
	case "max_connections": options.server.max_connections = number
	case "max_rooms": options.server.max_rooms = number
	case "timeout_seconds": options.server.idle_timeout = time.Duration(number) * time.Second
	case "packets_per_second": options.server.packets_per_second = number
	}
	return ""
}

@(private="file")
set_run_seconds :: proc(options: ^Relay_Options, seconds: f64) -> string {
	if !(seconds > 0 && seconds <= 86400) {
		return "run_seconds must be greater than 0 and at most 86400"
	}
	duration := time.Duration(seconds * f64(time.Second))
	if duration <= 0 {return "run_seconds is too small"}
	options.run_duration = duration
	return ""
}

@(private="file")
config_number :: proc(value: json.Value) -> (f64, bool) {
	#partial switch number in value {
	case json.Integer: return f64(number), true
	case json.Float: return number, true
	}
	return 0, false
}

@(private="file")
validate_options :: proc(options: Relay_Options) -> string {
	if options.server.max_rooms > options.server.max_connections {
		return "max_rooms must not exceed max_connections"
	}
	return ""
}

// Apply a complete, validated object atomically. Endpoint parsing owns no JSON
// strings, so all file/JSON allocations can be released before the server starts.
parse_config_json :: proc(data: []u8, options: ^Relay_Options) -> string {
	// The core decoder accepts a leading JSON value. Require the whole file
	// to contain exactly one value, including rejecting trailing garbage.
	parser := json.make_parser(data, spec = .JSON, parse_integers = true, allocator = mem.nil_allocator())
	if !json.validate_value(&parser) || parser.curr_token.kind != .EOF {return "invalid config JSON"}
	// The core parser also tolerates trailing commas and drops empty object
	// keys. Neither is a supported configuration field/syntax here.
	tokenizer := json.make_tokenizer(string(data), spec = .JSON)
	previous := json.Token_Kind.Invalid
	for {
		token, error := json.get_token(&tokenizer)
		if token.kind == .EOF {break}
		if error != nil {return "invalid config JSON"}
		if previous == .Comma && (token.kind == .Close_Brace || token.kind == .Close_Bracket) {return "invalid config JSON"}
		if (previous == .Open_Brace || previous == .Comma) && token.kind == .String && token.text == "\"\"" {return "unknown relay config field: (empty)"}
		previous = token.kind
	}
	// Parse numbers as floats to avoid an overflowing JSON integer wrapping
	// into the supported range; all limits are checked before conversion.
	value, parse_error := json.parse(data, spec = .JSON, parse_integers = false)
	defer json.destroy_value(value)
	if parse_error != nil {return "invalid config JSON"}
	object, is_object := value.(json.Object)
	if !is_object {return "relay config must be a JSON object"}
	parsed := options^
	for key, field in object {
		switch key {
		case "$schema":
			if _, valid := field.(json.String); !valid {return "$schema must be a string"}
		case "listen":
			text, valid := field.(json.String)
			if !valid {return "listen must be a string"}
			endpoint, valid_endpoint := parse_listen(text)
			if !valid_endpoint {return "listen requires a numeric IP endpoint, such as 127.0.0.1:7777"}
			parsed.server.listen = endpoint
		case "max_connections", "max_rooms", "timeout_seconds", "packets_per_second":
			number, valid := config_number(field)
			minimum, maximum := integer_bounds(key)
			// Check the small supported range before converting to an integer.
			if !valid || !(number >= f64(minimum) && number <= f64(maximum)) || math.trunc(number) != number {
				return fmt.tprintf("%s must be an integer between %d and %d", key, minimum, maximum)
			}
			if error := set_integer_option(&parsed, key, int(number)); error != "" {return error}
		case "run_seconds":
			seconds, valid := config_number(field)
			if !valid {return "run_seconds must be a number"}
			if error := set_run_seconds(&parsed, seconds); error != "" {return error}
		case "udp_enabled":
			enabled, valid := field.(json.Boolean)
			if !valid {return "udp_enabled must be a boolean"}
			parsed.server.udp_enabled, parsed.server.udp_configured = bool(enabled), true
		case:
			return fmt.tprintf("unknown relay config field: %s", key)
		}
	}
	if error := validate_options(parsed); error != "" {return error}
	options^ = parsed
	return ""
}

// Arguments exclude the executable name. Select the file first, then apply all
// CLI settings so precedence is independent of where --config appears.
load_options :: proc(args: []string) -> (Relay_Options, bool, string) {
	options := default_options()
	path := DEFAULT_CONFIG_PATH
	explicit_path := false
	for index := 0; index < len(args); index += 1 {
		option := args[index]
		if option == "--help" || option == "-h" {return options, true, ""}
		switch option {
		case "--udp", "--no-udp": continue
		case "--config", "--listen", "--max-connections", "--max-rooms", "--timeout-seconds", "--packets-per-second", "--run-seconds":
		case: return options, false, fmt.tprintf("Unknown option: %s", option)
		}
		if index + 1 >= len(args) {return options, false, fmt.tprintf("Missing value for %s", option)}
		index += 1
		if option == "--config" {
			path = args[index]
			explicit_path = true
			if path == "" {return options, false, "--config requires a file path"}
		}
	}

	data, read_error := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if read_error != nil {
		if explicit_path || read_error != .Not_Exist {
			return options, false, fmt.tprintf("Could not read relay config %s: %v", path, read_error)
		}
	} else if error := parse_config_json(data, &options); error != "" {
		return options, false, fmt.tprintf("Invalid relay config %s: %s", path, error)
	}

	for index := 0; index < len(args); index += 1 {
		option := args[index]
		if option == "--udp" || option == "--no-udp" {
			options.server.udp_enabled, options.server.udp_configured = option == "--udp", true
			continue
		}
		index += 1
		text := args[index]
		switch option {
		case "--config": continue
		case "--listen":
			endpoint, valid := parse_listen(text)
			if !valid {return options, false, "--listen requires a numeric IP endpoint, such as 127.0.0.1:7777"}
			options.server.listen = endpoint
		case "--run-seconds":
			seconds, valid := strconv.parse_f64(text)
			if !valid {return options, false, "Invalid number for --run-seconds"}
			if error := set_run_seconds(&options, seconds); error != "" {return options, false, error}
		case:
			number, valid := strconv.parse_int(text, 10)
			if !valid {return options, false, fmt.tprintf("Invalid integer for %s", option)}
			key := ""
			switch option {
			case "--max-connections": key = "max_connections"
			case "--max-rooms": key = "max_rooms"
			case "--timeout-seconds": key = "timeout_seconds"
			case "--packets-per-second": key = "packets_per_second"
			}
			if error := set_integer_option(&options, key, number); error != "" {return options, false, error}
		}
	}
	return options, false, validate_options(options)
}
