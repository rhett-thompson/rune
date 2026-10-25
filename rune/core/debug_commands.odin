package core

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "rune:assets"
import "rune:console"
import "rune:ecs"
import "rune:input"
import "rune:scene"
import rl "vendor:raylib"

Max_Debug_Frames :: 600
Fast_Steps_Per_Frame :: 8

Debug_State :: struct {
	world: ^ecs.World,
	// Generation-bound handle only; geometry and cameras are reacquired per frame.
	picked_entity: ecs.Entity,
	picked_dimension: Debug_Pick_Dimension,
	paused: bool,
	steps_remaining: int,
	steps_requested: int,
	fast_step: bool,
	frame: u64,
	simulation_time: f64,
	simulation_updates: u64,
	fixed_steps: u64,
	fps: f64,
	// Owns the console-selected filter; Settings borrows it between frames.
	navmesh_entity: string,
	profile_count: int,
	profile_target: int,
	profile_samples: [Max_Debug_Frames]Profile_Sample,
	sample: Profile_Sample,
	frame_started: f64,
}

Profile_Sample :: struct {
	frame_ms, update_ms, fixed_update_ms, render_ms: f64,
}

register_debug_commands :: proc(dev: ^console.Console) {
	console.register(dev, "enable", "Enable entity subtree: enable <entity-id>.", enable_command, debug_argument_completion)
	console.register(dev, "disable", "Suspend entity subtree: disable <entity-id>.", disable_command, debug_argument_completion)
	console.register(dev, "window", "Inspect display or change mode: window [windowed|borderless|fullscreen].", window_command, debug_argument_completion)
	console.register(dev, "status", "Report scene, timing, camera, entity count, and errors.", status_command)
	console.register(dev, "entities", "List entities: entities [component].", entities_command, debug_argument_completion)
	console.register(dev, "inspect", "Current data: inspect <entity-id> [component].", inspect_command, debug_argument_completion)
	console.register(dev, "pause", "Pause simulation while rendering and console continue.", pause_command)
	console.register(dev, "resume", "Resume simulation.", resume_command)
	console.register(dev, "step", "Advance paused simulation: step [--fast] [count, 1..600].", step_command, debug_argument_completion)
	console.register(dev, "input", "Override action: input <action> press|release|clear.", input_command, debug_argument_completion)
	console.register(dev, "pads", "List connected gamepads and live axis values.", pads_command)
	console.register(dev, "quit", "Exit the active engine loop.", quit_command)
	console.register(dev, "set", "Runtime edit: set <id> <Component.field> <JSON-value>.", set_command, debug_argument_completion)
	console.register(dev, "reload", "Reload the active scene from disk; discard runtime edits.", reload_command)
	console.register(dev, "profile", "Sample CPU/frame timings: profile [frames, 1..600].", profile_command)
	console.register(dev, "memory", "Known World/asset backing buffers and texture GPU estimates.", memory_command)
	console.register(dev, "navmesh", "Show navigation surfaces: navmesh [on [entity-id]|off].", navmesh_command, debug_argument_completion)
}

quit_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok || !no_arguments(dev, arguments) {return}
	request_exit(engine)
	console.set_result(dev, struct {exit_requested: bool}{true})
}

Gamepad_Summary :: struct {
	index: i32,
	name: string,
	axis_count: i32,
	axes: []f32,
}

pads_command :: proc(dev: ^console.Console, arguments: string) {
	_, ok := command_engine(dev)
	if !ok || !no_arguments(dev, arguments) {return}
	pads := make([dynamic]Gamepad_Summary, context.temp_allocator)
	for pad: i32 = 0; pad < 4; pad += 1 {
		if !rl.IsGamepadAvailable(pad) {continue}
		axis_count := max(0, rl.GetGamepadAxisCount(pad))
		axes := make([]f32, int(axis_count), context.temp_allocator)
		for axis in 0..<axis_count {
			axes[axis] = rl.GetGamepadAxisMovement(pad, rl.GamepadAxis(axis))
		}
		append(&pads, Gamepad_Summary{index=pad, name=string(rl.GetGamepadName(pad)), axis_count=axis_count, axes=axes})
	}
	console.set_result(dev, pads[:])
}

navmesh_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok {return}
	mode, rest := take_word(arguments)
	if mode != "" {
		id, extra := take_word(rest)
		runtime_entity: ecs.Entity
		if (mode != "on" && mode != "off") || extra != "" || (mode == "off" && id != "") {
			console.error(dev, "Usage: navmesh [on [entity-id]|off].")
			return
		}
		if id != "" {
			_, world, attached := command_world(dev)
			if !attached {return}
			entity, found := resolve_debug_entity(dev, world, id)
			if !found {return}
			if !ecs.has_component_data(world, entity, "NavMesh3D") {
				console.error(dev, fmt.tprintf("NavMesh3D scene entity not found: %s", id))
				return
			}
			// Resolve the alias now: changing the current pick cannot redirect a
			// navigation filter that is already enabled. IDs survive reloads;
			// unnamed entities use a generation-bound runtime handle instead.
			id = entity_label(world, entity)
			if scene_id, has_id := ecs.entity_id(world, entity); !has_id || scene_id == "" {runtime_entity = entity}
		}
		filter: string
		if id != "" {
			cloned, allocation_error := strings.clone(id)
			if allocation_error != nil {console.error(dev, "Could not retain navmesh entity ID."); return}
			filter = cloned
		}
		delete(engine.debug.navmesh_entity)
		engine.debug.navmesh_entity = filter
		engine.gizmos.navmesh_entity = filter
		engine.gizmos.navmesh_runtime_entity = runtime_entity
		engine.gizmos.navmeshes = mode == "on"
	}
	console.info(dev, fmt.tprintf("Navmesh display %s (%s).",
		"on" if engine.gizmos.navmeshes else "off",
		engine.gizmos.navmesh_entity if engine.gizmos.navmesh_entity != "" else "all entities"))
	console.set_result(dev, struct {enabled: bool, entity: string}{engine.gizmos.navmeshes, engine.gizmos.navmesh_entity})
}

memory_command :: proc(dev: ^console.Console, arguments: string) {
	engine, world, ok := command_world(dev)
	if !ok || !no_arguments(dev, arguments) {return}
	console.set_result(dev, struct {
		world: ecs.Memory_Stats,
		assets: assets.Memory_Stats,
	}{ecs.memory_stats(world), assets.memory_stats(&engine.assets)})
}

bind_debug_console :: proc(engine: ^Engine, world: ^ecs.World) {
	if engine.debug.world != world {clear_debug_selection(engine)}
	engine.console.user_data = engine
	engine.debug.world = world
}

// A quit dispatched during begin_frame skips rendering, so acknowledge its
// remote request before the loop releases the current frame's scratch memory.
@(private)
finish_exit_console :: proc(engine: ^Engine) {
	if !engine.exit_requested {return}
	engine.console.frame_metadata = debug_frame_metadata(engine)
	stop_debug_console(engine)
}

command_engine :: proc(dev: ^console.Console) -> (^Engine, bool) {
	engine := cast(^Engine)dev.user_data
	if engine == nil {
		console.error(dev, "Command requires an engine loop.")
		return nil, false
	}
	return engine, true
}

command_world :: proc(dev: ^console.Console) -> (^Engine, ^ecs.World, bool) {
	engine, ok := command_engine(dev)
	if !ok {return nil, nil, false}
	if engine.debug.world == nil {
		console.error(dev, "No scene World is attached to this loop.")
		return engine, nil, false
	}
	return engine, engine.debug.world, true
}

take_word :: proc(arguments: string) -> (string, string) {
	return console.take_argument(arguments)
}

// Component filters historically consume the whole remaining text, including
// spaces in custom component names. Completed quoted filters use JSON syntax.
take_component_argument :: proc(arguments: string) -> (string, bool) {
	name := strings.trim_space(arguments)
	if name == "" || name[0] != '"' {return name, true}
	return console.decode_argument(name)
}

no_arguments :: proc(dev: ^console.Console, arguments: string) -> bool {
	if arguments != "" {
		console.error(dev, "This command takes no arguments.")
		return false
	}
	return true
}

entity_label :: proc(world: ^ecs.World, entity: ecs.Entity) -> string {
	if entity == 0 {return ""}
	if id, found := ecs.entity_id(world, entity); found && id != "" {return id}
	return fmt.tprintf("@%d", u64(entity))
}

// Return the live selection for custom console commands without producing
// output. A handle is meaningful only in its currently bound World generation;
// never fall back to a matching ID after scene replacement or deletion.
// Disabled entities remain selected so enable @picked can restore them.
debug_picked_entity :: proc(engine: ^Engine) -> (ecs.Entity, bool) {
	when Player_Build {return 0, false}
	if engine == nil || !engine.console.is_open || engine.debug.world == nil || engine.debug.picked_dimension == .None {return 0, false}
	entity := engine.debug.picked_entity
	world := engine.debug.world
	if !ecs.is_alive(world, entity) {return 0, false}
	return entity, true
}

// Shared nonlogging resolution keeps completion and command execution aligned.
// Exact @picked is reserved before looking up scene IDs. Other IDs retain their
// historical precedence over numeric @handle labels.
@(private)
debug_entity :: proc(engine: ^Engine, world: ^ecs.World, label: string) -> (ecs.Entity, bool) {
	if world == nil {return 0, false}
	if label == "@picked" {
		if engine == nil || engine.debug.world != world {return 0, false}
		return debug_picked_entity(engine)
	}
	return debug_literal_entity(world, label)
}

@(private)
debug_literal_entity :: proc(world: ^ecs.World, label: string) -> (ecs.Entity, bool) {
	if entity, found := ecs.find_entity_by_id(world, label); found {return entity, true}
	if strings.has_prefix(label, "@") {
		handle, parsed := strconv.parse_uint(label[1:], 10)
		if parsed && ecs.is_alive(world, ecs.Entity(handle)) {return ecs.Entity(handle), true}
	}
	return 0, false
}

resolve_debug_entity :: proc(dev: ^console.Console, world: ^ecs.World, label: string) -> (ecs.Entity, bool) {
	engine := cast(^Engine)dev.user_data
	if entity, found := debug_entity(engine, world, label); found {return entity, true}
	if label == "@picked" {console.error(dev, "No object is currently picked.")
	} else {console.error(dev, fmt.tprintf("Entity not found: %s", label))}
	return 0, false
}

debug_frame_metadata :: proc(engine: ^Engine) -> console.Frame_Metadata {
	data := console.Frame_Metadata {
		frame = engine.debug.frame,
		simulation_time = engine.debug.simulation_time,
		simulation_steps = engine.debug.fixed_steps,
		scene = engine.active_scene_path,
	}
	if world := engine.debug.world; world != nil {
		if entity, _, found := ecs.active_camera_2d(world); found {data.camera_2d = entity_label(world, entity)}
		if entity, _, found := ecs.active_camera_3d(world); found {data.camera_3d = entity_label(world, entity)}
	}
	return data
}

debug_status :: proc(engine: ^Engine) {
	count := 0
	if engine.debug.world != nil {count = engine.debug.world.entity_count}
	errors := make([dynamic]console.Log_Entry, context.temp_allocator)
	for entry in console.read_logs(&engine.console, 0).entries {
		if entry.level == "error" {append(&errors, entry)}
	}
	console.set_result(&engine.console, struct {
		metadata: console.Frame_Metadata,
		paused: bool,
		fps: f64,
		fixed_delta_time: f32,
		simulation_updates: u64,
		entity_count: int,
		recent_errors: []console.Log_Entry,
	}{debug_frame_metadata(engine), is_paused(engine), engine.debug.fps,
		engine.fixed_delta_time, engine.debug.simulation_updates, count, errors[:]})
}

status_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if ok && no_arguments(dev, arguments) {debug_status(engine)}
}

Entity_Summary :: struct {
	id, name, parent: string,
	components: []string,
	enabled, enabled_in_hierarchy: bool,
}

entity_summary :: proc(world: ^ecs.World, entity: ecs.Entity) -> Entity_Summary {
	names := make([dynamic]string, context.temp_allocator)
	for name, values in world.component_data {
		if _, found := values[entity]; found {append(&names, name)}
	}
	slice.sort(names[:])
	return {entity_label(world, entity), world.entity_names[entity], entity_label(world, world.parents[entity]), names[:], ecs.is_locally_enabled(world, entity), ecs.is_enabled(world, entity)}
}

entities_command :: proc(dev: ^console.Console, arguments: string) {
	engine, world, ok := command_world(dev)
	if !ok {return}
	component, valid := take_component_argument(arguments)
	if !valid || (component != "" && !ecs.has_component(&engine.registry, component)) {
		console.error(dev, "Unknown component filter.")
		return
	}
	rows := make([dynamic]Entity_Summary, context.temp_allocator)
	for entity in world.entities {
		if component != "" && !ecs.has_component_data(world, entity, component) {continue}
		append(&rows, entity_summary(world, entity))
	}
	slice.sort_by(rows[:], proc(a, b: Entity_Summary) -> bool {return a.id < b.id})
	console.set_result(dev, rows[:])
}

inspect_command :: proc(dev: ^console.Console, arguments: string) {
	_, world, ok := command_world(dev)
	if !ok {return}
	id, rest := take_word(arguments)
	component, valid := take_component_argument(rest)
	if id == "" || !valid {
		console.error(dev, "Usage: inspect <entity-id> [component]")
		return
	}
	entity, found := resolve_debug_entity(dev, world, id)
	if !found {return}
	inspect_debug_entity(dev, world, entity, component)
}

// Both the inspect command and scene picking snapshot the same current data.
// Direct entity access also handles IDs too long to fit a command input line.
inspect_debug_entity :: proc(dev: ^console.Console, world: ^ecs.World, entity: ecs.Entity, component: string = "") -> bool {
	if world == nil || !ecs.is_alive(world, entity) {return false}
	summary := entity_summary(world, entity)
	components := make(json.Object, context.temp_allocator)
	names := summary.components
	if component != "" {names = []string{component}}
	for name in names {
		value, valid := ecs.runtime_component_json(world, entity, name)
		if !valid {
			console.error(dev, fmt.tprintf("Cannot inspect component: %s", name))
			return false
		}
		components[name] = value
	}
	children := make([dynamic]string, context.temp_allocator)
	for child in ecs.child_entities(world, entity) {append(&children, entity_label(world, child))}
	slice.sort(children[:])
	errors := dev.error_count
	console.set_result(dev, struct {
		entity: Entity_Summary,
		children: []string,
		components: json.Object,
	}{summary, children[:], components})
	return dev.error_count == errors
}

pause_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok || !no_arguments(dev, arguments) {return}
	engine.debug.paused = true
	engine.fixed_accumulator = 0
	debug_status(engine)
}

resume_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok || !no_arguments(dev, arguments) {return}
	engine.debug.paused = false
	engine.fixed_accumulator = 0
	debug_status(engine)
}

debug_frame_count :: proc(dev: ^console.Console, arguments: string, fallback: int) -> (int, bool) {
	if arguments == "" {return fallback, true}
	count, ok := strconv.parse_int(arguments, 10)
	if !ok || count < 1 || count > Max_Debug_Frames {
		console.error(dev, "Frame count must be from 1 to 600.")
		return 0, false
	}
	return int(count), true
}

step_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok {return}
	if !is_paused(engine) {
		console.error(dev, "Pause simulation before stepping.")
		return
	}
	count_arguments := arguments
	option, rest := take_word(arguments)
	fast := option == "--fast"
	if fast {count_arguments = rest}
	count, valid := debug_frame_count(dev, count_arguments, 1)
	if !valid {return}
	engine.debug.steps_remaining = count
	engine.debug.steps_requested = count
	engine.debug.fast_step = fast
	set_step_uncapped(engine, fast)
	dev.defer_reply = true
}

input_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok {return}
	action, rest := take_word(arguments)
	operation, extra := take_word(rest)
	if extra != "" || (operation != "press" && operation != "release" && operation != "clear") {
		console.error(dev, "Usage: input <action> press|release|clear")
		return
	}
	valid := input.clear_injected_action(&engine.input, action) if operation == "clear" else input.inject_action(&engine.input, action, operation == "press")
	if !valid {
		console.error(dev, "Unknown input action.")
		return
	}
	console.set_result(dev, struct {action, operation: string}{action, operation})
}

set_command :: proc(dev: ^console.Console, arguments: string) {
	engine, world, ok := command_world(dev)
	if !ok {return}
	id, rest := take_word(arguments)
	path, encoded := take_word(rest)
	dot := strings.index_byte(path, '.')
	if id == "" || dot <= 0 || dot == len(path)-1 || encoded == "" {
		console.error(dev, "Usage: set <id> <Component.field> <JSON-value>")
		return
	}
	entity, found := resolve_debug_entity(dev, world, id)
	if !found {return}
	value: json.Value
	if json.unmarshal(transmute([]u8)encoded, &value, allocator = context.temp_allocator) != nil {
		console.error(dev, "Value must be valid JSON.")
		return
	}
	component, field := path[:dot], path[dot+1:]
	if !ecs.set_runtime_field(world, &engine.registry, entity, component, field, value) {
		console.error(dev, "Invalid field or value; component was not changed.")
		return
	}
	encoded_id, encode_error := json.marshal(id, allocator = context.temp_allocator)
	encoded_component, component_error := json.marshal(component, allocator = context.temp_allocator)
	if encode_error == nil && component_error == nil {
		inspect_command(dev, fmt.tprintf("%s %s", string(encoded_id), string(encoded_component)))
	}
}

reload_command :: proc(dev: ^console.Console, arguments: string) {
	engine, world, ok := command_world(dev)
	if !ok || !no_arguments(dev, arguments) {return}
	if engine.active_scene_path == "" {
		console.error(dev, "No scene path to reload.")
		return
	}
	replacement, loaded := scene.load_with_layers(engine.active_scene_path, &engine.registry, engine.project.layers)
	if !loaded {
		console.error(dev, scene.last_load_error())
		return
	}
	ecs.destroy(world)
	world^ = replacement
	engine.active_scene_path = watch_scene(engine, engine.active_scene_path)
	engine.fixed_accumulator = 0
	run_scene_reload_systems(engine, world)
	debug_status(engine)
}

profile_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok {return}
	count, valid := debug_frame_count(dev, arguments, 120)
	if !valid {return}
	engine.debug.profile_count = 0
	engine.debug.profile_target = count
	dev.defer_reply = true
}

// Snapshot once per rendered frame. A queued save or exit may end the frame's
// ticks early; normal stepping and ordinary simulation retain one update/frame.
debug_simulation_budget :: proc(engine: ^Engine) -> int {
	when Player_Build {return 1}
	if engine.debug.fast_step {return min(Fast_Steps_Per_Frame, engine.debug.steps_remaining)}
	return 1
}

// Live input is sampled once per frame. Additional fast ticks must not replay
// cached button edges or mouse displacement. Injection is applied afterward by
// debug_simulation_tick, so commands issued during simulation retain their edge.
debug_prepare_simulation_tick :: proc(engine: ^Engine, tick_index: int) {
	when Player_Build {return}
	if engine.debug.fast_step && tick_index > 0 {input.clear_transients(&engine.input)}
}

// Stop engine-owned commands before loop teardown. Custom engine loops use this
// instead of console.stop_remote alone to release temporary pacing overrides.
stop_debug_console :: proc(engine: ^Engine) {
	if engine == nil {return}
	set_step_uncapped(engine, false)
	engine.debug.fast_step = false
	engine.debug.steps_remaining = 0
	console.stop_remote(&engine.console)
}

// Select a simulation tick only after console commands have been dispatched.
// Paused frames still sample real input, draw, poll files, and accept commands.
debug_simulation_tick :: proc(engine: ^Engine) -> bool {
	when Player_Build {
		if engine.game_paused {engine.delta_time = 0; return false}
		return true
	}
	if is_paused(engine) || engine.debug.steps_remaining > 0 {
		if engine.debug.steps_remaining == 0 {
			engine.delta_time = 0
			return false
		}
		engine.delta_time = engine.fixed_delta_time
		engine.fixed_accumulator = 0
	}
	input.apply_injected_actions(&engine.input)
	return true
}

debug_simulation_finished :: proc(engine: ^Engine) {
	engine.debug.simulation_time += f64(engine.delta_time)
	engine.debug.simulation_updates += 1
	when Player_Build {return}
	if engine.debug.steps_remaining > 0 {
		engine.debug.steps_remaining -= 1
		if engine.debug.steps_remaining == 0 {
			engine.debug.fast_step = false
			set_step_uncapped(engine, false)
			engine.console.defer_reply = false
			console.info(&engine.console, fmt.tprintf("Advanced %d simulation steps.", engine.debug.steps_requested))
			debug_status(engine)
		}
	}
}

Timing_Summary :: struct {mean_ms, max_ms, p95_ms: f64}
timing_summary :: proc(values: []f64) -> Timing_Summary {
	sum: f64
	for value in values {sum += value}
	slice.sort(values)
	return {sum / f64(len(values)), values[len(values)-1], values[(len(values)*95+99)/100-1]}
}

debug_profile_finished_frame :: proc(engine: ^Engine) {
	when Player_Build {return}
	debug := &engine.debug
	if debug.profile_target == 0 {return}
	debug.sample.frame_ms = (rl.GetTime() - debug.frame_started) * 1000
	debug.profile_samples[debug.profile_count] = debug.sample
	debug.profile_count += 1
	if debug.profile_count < debug.profile_target {return}
	frame := make([]f64, debug.profile_count, context.temp_allocator)
	update := make([]f64, debug.profile_count, context.temp_allocator)
	fixed := make([]f64, debug.profile_count, context.temp_allocator)
	render := make([]f64, debug.profile_count, context.temp_allocator)
	for index in 0..<debug.profile_count {
		sample := debug.profile_samples[index]
		frame[index], update[index], fixed[index], render[index] = sample.frame_ms, sample.update_ms, sample.fixed_update_ms, sample.render_ms
	}
	console.set_result(&engine.console, struct {
		frames: int,
		frame, update, fixed_update, render_submission: Timing_Summary,
	}{debug.profile_count, timing_summary(frame), timing_summary(update), timing_summary(fixed), timing_summary(render)})
	debug.profile_target = 0
	engine.console.defer_reply = false
	console.info(&engine.console, "Profile complete (CPU timings; frame includes presentation/wait).")
	console.finish_remote(&engine.console)
}

enable_command :: proc(dev: ^console.Console, arguments: string) {activation_command(dev, arguments, true)}
disable_command :: proc(dev: ^console.Console, arguments: string) {activation_command(dev, arguments, false)}
activation_command :: proc(dev: ^console.Console, arguments: string, enabled: bool) {
	_, world, ok := command_world(dev)
	if !ok {return}
	id, extra := take_word(arguments)
	if id == "" || extra != "" {console.error(dev, "Usage: enable|disable <entity-id>"); return}
	entity, found := resolve_debug_entity(dev, world, id)
	if !found {return}
	if !ecs.set_enabled(world, entity, enabled) {console.error(dev, "Could not change entity activation."); return}
	console.set_result(dev, entity_summary(world, entity))
}
