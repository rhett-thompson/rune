package main

import example_text "../shared/text"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:input"
import "rune:network"
import "rune:replication"
import "rune:ui"
import rl "vendor:raylib"

Options :: struct {
	server, room_code, capture_path: string,
	host, headless, scripted, hidden, use_udp: bool,
	duration: time.Duration,
}
options: Options
last_log: time.Tick
exit_code: int
stats_visible: bool = true

App_View :: enum {Lobby, Arena}
Pending_Connection :: struct {job: Connection_Job, host: bool, code: [16]u8}
app_view: App_View
app_started: time.Tick
direct_start: bool
pending_connections: [4]Pending_Connection
active_connection: int = -1

print_help :: proc() {
	fmt.println("Usage: relay_multiplayer [--host | --join <room-code>] [options]")
	fmt.println("Start without a mode to open the Host/Join menu.")
	fmt.println("  --server <host:port>     Relay endpoint; default 127.0.0.1:7777")
	fmt.println("  --transport udp|tcp     Gameplay transport; default udp (room controls stay reliable)")
	fmt.println("  --host                  Create a room and run the authoritative simulation")
	fmt.println("  --join <room-code>      Join the host's 16-character room code")
	fmt.println("  --run-seconds <number>  Optional finite run, greater than 0 and at most 3600")
	fmt.println("  --headless              Run the same ECS simulation without opening a window")
	fmt.println("  --scripted              Generate repeatable movement input for checks")
	fmt.println("  --hidden                Keep a windowed rendering check hidden")
	fmt.println("  --capture <path.png>    Save a screenshot at the end of a finite windowed run")
	fmt.println("  --help                  Show this help")
	fmt.println("Window controls: WASD or arrows to move; Escape leaves the room or closes the menu.")
	fmt.println("  F2 toggles the network stats display.")
}

parse_options :: proc() -> (result: Options, code: int) {
	result.server = "127.0.0.1:7777"
	result.use_udp = true
	for index := 1; index < len(os.args); index += 1 {
		option := os.args[index]
		if option == "--help" || option == "-h" {print_help(); return {}, -1}
		// Rune's engine handles the shared launcher console option.
		if strings.has_prefix(option, "--console-dir=") {
			if len(option) == len("--console-dir=") {fmt.eprintln("--console-dir requires a directory"); return {}, 2}
			continue
		}
		switch option {
		case "--host":
			if result.host || result.room_code != "" {fmt.eprintln("Choose exactly one of --host or --join"); return {}, 2}
			result.host = true
		case "--headless": result.headless = true
		case "--scripted": result.scripted = true
		case "--hidden": result.hidden = true
		case "--server", "--join", "--run-seconds", "--capture", "--transport":
			if index + 1 >= len(os.args) {fmt.eprintln("Missing value for", option); return {}, 2}
			index += 1
			value := os.args[index]
			switch option {
			case "--server":
				if value == "" {fmt.eprintln("--server requires an endpoint"); return {}, 2}
				result.server = value
			case "--transport":
				if value != "udp" && value != "tcp" {fmt.eprintln("--transport requires udp or tcp"); return {}, 2}
				result.use_udp = value == "udp"
			case "--join":
				if result.host || result.room_code != "" || !network.room_code_valid(transmute([]u8)value) {fmt.eprintln("--join requires a room code and cannot be combined with --host"); return {}, 2}
				result.room_code = value
			case "--run-seconds":
				seconds, valid := strconv.parse_f64(value)
				if !valid || !(seconds > 0 && seconds <= 3600) {fmt.eprintln("--run-seconds must be greater than 0 and at most 3600"); return {}, 2}
				result.duration = time.Duration(seconds * f64(time.Second))
				if result.duration <= 0 {return {}, 2}
			case "--capture": result.capture_path = value
			}
		case:
			fmt.eprintln("Unknown option:", option); return {}, 2
		}
	}
	if result.headless && !result.host && result.room_code == "" {fmt.eprintln("--headless requires --host or --join"); return {}, 2}
	if result.headless && result.duration == 0 {result.duration = 15 * time.Second}
	if result.capture_path != "" && (result.headless || result.duration == 0) {fmt.eprintln("--capture requires a finite windowed run"); return {}, 2}
	return result, 0
}

capture_frame :: proc(path: string) -> bool {
	// TakeScreenshot prefixes the working directory even for absolute Windows
	// paths. Export the captured image directly so either path form works.
	image := rl.LoadImageFromScreen()
	if image.data == nil {return false}
	defer rl.UnloadImage(image)
	return rl.ExportImage(image, fmt.ctprintf("%s", path))
}

connect_game :: proc() -> bool {
	game_state = {hosting = options.host, scripted = options.scripted, started = time.tick_now(), status = .Waiting, message = "Waiting for the relay to confirm the room."}
	if err := network.connect(&game_state.client, options.server, use_udp=options.use_udp); err != nil {fmt.eprintln("Could not connect to relay:", err); return false}
	requested := network.create_room(&game_state.client, 2) if options.host else network.join_room(&game_state.client, options.room_code)
	if !requested {network.disconnect(&game_state.client); return false}
	last_log = game_state.started
	return true
}

return_to_menu :: proc(world: ^ecs.World, error: string = "") {
	if active_connection >= 0 {connection_cancel(&pending_connections[active_connection].job)}
	active_connection = -1
	game_cleanup(&game_state, world)
	game_state = {}
	app_view = .Lobby
	lobby.busy = false
	lobby.error = error
	lobby.code_field.active = false
	lobby.server_field.active = false
	ui.reset_focus(&lobby.interface)
}

start_menu_connection :: proc(world: ^ecs.World, host: bool) {
	if lobby.busy {return}
	server := menu_server(&lobby)
	if !menu_server_valid(server) || len(server) >= 256 {lobby.error = "Enter a valid relay address shorter than 256 characters."; return}
	code, valid := menu_code(&lobby)
	if !host && !valid {lobby.error = "Enter the host's 16-character room code."; return}
	free := -1
	for &pending, index in pending_connections {if !pending.job.running {free = index; break}}
	if free < 0 {lobby.error = "Previous connection attempts are still finishing. Try again shortly."; return}
	game_cleanup(&game_state, world)
	direct_start = false
	exit_code = 0
	pending := &pending_connections[free]
	pending.host, pending.code = host, code
	if !connection_start(&pending.job, server, use_udp=options.use_udp) {lobby.error = "Could not start the connection. Please try again."; return}
	active_connection = free
	lobby.busy = true
	lobby.error = ""
	lobby.code_field.active = false
	lobby.server_field.active = false
	ui.reset_focus(&lobby.interface)
}

poll_menu_connections :: proc(world: ^ecs.World) {
	for &pending, index in pending_connections {
		if !connection_ready(&pending.job) {continue}
		if pending.job.cancelled || index != active_connection {connection_take(&pending.job, nil); continue}
		client: network.Client
		err, ready := connection_take(&pending.job, &client)
		if !ready {continue}
		active_connection = -1
		lobby.busy = false
		if err != nil {
			fmt.eprintln("Could not connect to relay:", err)
			lobby.error = "Could not connect. Check the relay address and that the server is running."
			continue
		}
		game_state = {client = client, hosting = pending.host, scripted = options.scripted, started = time.tick_now(), status = .Waiting, message = "Waiting for the relay to confirm the room."}
		requested := network.create_room(&game_state.client, 2) if pending.host else network.join_room(&game_state.client, string(pending.code[:]))
		if !requested {return_to_menu(world, "Could not request the room. Please try again."); continue}
		app_view = .Arena
		last_log = game_state.started
		ui.reset_focus(&lobby.interface)
	}
}

finish_window_run :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	if options.duration == 0 || time.tick_since(app_started) < options.duration {return}
	if app_view == .Arena {log_game(&game_state, world)}
	if options.capture_path != "" && !capture_frame(options.capture_path) {fmt.eprintln("Could not save the screenshot"); exit_code = 1}
	rune.request_exit(engine)
}

on_network :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	escape_allowed := !console.is_open(rune.developer_console(engine)) && !rune.input_state(engine).captured
	poll_menu_connections(world)
	if app_view == .Lobby {
		was_editing := lobby.code_field.active || lobby.server_field.active
		action := menu_update(engine)
		switch action {
		case .Host: start_menu_connection(world, true)
		case .Join: start_menu_connection(world, false)
		case .Cancel: return_to_menu(world)
		case .None, .Leave, .Copy_Code:
		}
		if !was_editing && action == .None && !lobby.busy && rl.IsKeyPressed(.ESCAPE) && escape_allowed {rune.request_exit(engine)}
		finish_window_run(engine, world)
		return
	}
	action := menu_session_update(engine, game_state.local_peer != 0 && game_state.status != .Closed && game_state.status != .Failed)
	if action == .Leave || (rl.IsKeyPressed(.ESCAPE) && escape_allowed) {
		return_to_menu(world)
		menu_update(engine)
		finish_window_run(engine, world)
		return
	}
	if action == .Copy_Code {rl.SetClipboardText(fmt.ctprintf("%s", string(game_state.room_code[:])))}
	game_state.local_axis = scripted_axis(&game_state) if game_state.scripted else [2]i8{
		i8(input.axis(rune.input_state(engine), "move_horizontal")),
		i8(input.axis(rune.input_state(engine), "move_vertical")),
	}
	game_pump(&game_state, world, rune.component_registry(engine))
	game_stats_update(&game_state, world, time.tick_now())
	if rl.IsWindowFocused() && escape_allowed && rl.IsKeyPressed(.F2) {stats_visible = !stats_visible}
	if game_state.status == .Failed {exit_code = 1}
	if game_state.status == .Failed && !direct_start && game_state.local_peer == 0 {
		message := game_state.message
		return_to_menu(world, message)
		exit_code = 0
		menu_update(engine)
		finish_window_run(engine, world)
		return
	}
	if game_state.status == .Failed || game_state.status == .Closed {
		finish_window_run(engine, world)
		return
	}
	if time.tick_since(last_log) >= time.Second {log_game(&game_state, world); last_log = time.tick_now()}
	finish_window_run(engine, world)
}

on_fixed_update :: proc(engine: ^rune.Engine, world: ^ecs.World) {if app_view == .Arena {game_fixed_update(&game_state, world, engine.fixed_delta_time)}}
on_presentation :: proc(engine: ^rune.Engine, world: ^ecs.World) {if app_view == .Arena {game_visual_update(&game_state, engine.frame_delta_time)}}
on_draw :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	if app_view == .Arena {draw_multiplayer(engine, world)}
	menu_draw()
}
on_shutdown :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	game_cleanup(&game_state, world)
	for &pending in pending_connections {connection_shutdown(&pending.job)}
	menu_destroy()
}

run_window :: proc() -> int {
	if options.hidden {rl.SetConfigFlags({.WINDOW_HIDDEN})}
	engine, ok := rune.init("examples/relay_multiplayer/project.json")
	if !ok {fmt.eprintln("Could not load the relay multiplayer project"); return 1}
	defer rune.shutdown(&engine)
	if !example_text.init(&engine.assets) || !replication.register(rune.component_registry(&engine)) {return 1}
	if !menu_init(options.server, options.room_code) {return 1}
	defer menu_destroy()
	rl.SetExitKey(rl.KeyboardKey(0))
	if !rune.register_system(&engine, {name = "relay_multiplayer", ui_update = on_network, fixed_update = on_fixed_update, update = on_presentation, draw = on_draw, shutdown = on_shutdown}) {return 1}
	if !rune.run(&engine) {fmt.eprintln("Could not run the relay multiplayer scene:", rune.last_scene_error()); return 1}
	return exit_code
}

run_headless :: proc() -> int {
	world := ecs.init()
	defer ecs.destroy(&world)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	if !ecs.register_builtin_components(&registry) || !replication.register(&registry) {return 1}
	defer game_cleanup(&game_state, &world)
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	previous_temp := context.temp_allocator
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	defer {context.temp_allocator = previous_temp}
	last_step := time.tick_now()
	for time.tick_since(game_state.started) < options.duration {
		game_state.local_axis = scripted_axis(&game_state) if game_state.scripted else [2]i8{}
		game_pump(&game_state, &world, &registry)
		game_stats_update(&game_state, &world, time.tick_now())
		if game_state.status == .Failed {return 1}
		if game_state.status == .Closed {return 0}
		for _ in 0..<8 {
			if time.tick_since(last_step) < STEP {break}
			last_step = time.tick_add(last_step, STEP)
			game_fixed_update(&game_state, &world, 1.0 / 60)
		}
		if game_state.status == .Failed {return 1}
		if time.tick_since(last_log) >= time.Second {log_game(&game_state, &world); last_log = time.tick_now()}
		mem.dynamic_arena_reset(&scratch)
		time.sleep(time.Millisecond)
	}
	log_game(&game_state, &world)
	return 0
}

run :: proc() -> int {
	parsed, code := parse_options()
	if code < 0 {return 0}
	if code != 0 {return code}
	options = parsed
	app_started = time.tick_now()
	direct_start = options.host || options.room_code != ""
	if direct_start {
		if !connect_game() {return 1}
		app_view = .Arena
	}
	defer network.disconnect(&game_state.client)
	return run_headless() if options.headless else run_window()
}

main :: proc() {if code := run(); code != 0 {os.exit(code)}}
