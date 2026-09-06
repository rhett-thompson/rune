package core

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "rune:console"
import "rune:ecs"
import "rune:input"
import "rune:scene"
import rl "vendor:raylib"

Max_Debug_Frames :: 600

Debug_State :: struct {
	world: ^ecs.World,
	paused: bool,
	steps_remaining: int,
	steps_requested: int,
	frame: u64,
	simulation_time: f64,
	simulation_updates: u64,
	fixed_steps: u64,
	fps: f64,
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
	console.register(dev, "window", "Inspect display or change mode: window [windowed|borderless|fullscreen].", window_command)
	console.register(dev, "status", "Report scene, timing, camera, entity count, and errors.", status_command)
	console.register(dev, "entities", "List entities: entities [component].", entities_command)
	console.register(dev, "inspect", "Current data: inspect <entity-id> [component].", inspect_command)
	console.register(dev, "pause", "Pause simulation while rendering and console continue.", pause_command)
	console.register(dev, "resume", "Resume simulation.", resume_command)
	console.register(dev, "step", "Advance paused simulation: step [count, 1..600].", step_command)
	console.register(dev, "input", "Override action: input <action> press|release|clear.", input_command)
	console.register(dev, "set", "Runtime edit: set <id> <Component.field> <JSON-value>.", set_command)
	console.register(dev, "reload", "Reload the active scene from disk; discard runtime edits.", reload_command)
	console.register(dev, "profile", "Sample CPU/frame timings: profile [frames, 1..600].", profile_command)
}

bind_debug_console :: proc(engine: ^Engine, world: ^ecs.World) {
	engine.console.user_data = engine
	engine.debug.world = world
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
	line := strings.trim_space(arguments)
	end := 0
	for end < len(line) && line[end] != ' ' && line[end] != '\t' {end += 1}
	return line[:end], strings.trim_space(line[end:])
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

resolve_debug_entity :: proc(dev: ^console.Console, world: ^ecs.World, label: string) -> (ecs.Entity, bool) {
	if entity, found := ecs.find_entity_by_id(world, label); found {return entity, true}
	if strings.has_prefix(label, "@") {
		handle, parsed := strconv.parse_uint(label[1:], 10)
		if parsed && ecs.is_alive(world, ecs.Entity(handle)) {return ecs.Entity(handle), true}
	}
	console.error(dev, fmt.tprintf("Entity not found: %s", label))
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
}

entity_summary :: proc(world: ^ecs.World, entity: ecs.Entity) -> Entity_Summary {
	names := make([dynamic]string, context.temp_allocator)
	for name, values in world.component_data {
		if _, found := values[entity]; found {append(&names, name)}
	}
	slice.sort(names[:])
	return {entity_label(world, entity), world.entity_names[entity], entity_label(world, world.parents[entity]), names[:]}
}

entities_command :: proc(dev: ^console.Console, arguments: string) {
	engine, world, ok := command_world(dev)
	if !ok {return}
	if arguments != "" && !ecs.has_component(&engine.registry, arguments) {
		console.error(dev, "Unknown component filter.")
		return
	}
	rows := make([dynamic]Entity_Summary, context.temp_allocator)
	for entity in world.entities {
		if arguments != "" && !ecs.has_component_data(world, entity, arguments) {continue}
		append(&rows, entity_summary(world, entity))
	}
	slice.sort_by(rows[:], proc(a, b: Entity_Summary) -> bool {return a.id < b.id})
	console.set_result(dev, rows[:])
}

inspect_command :: proc(dev: ^console.Console, arguments: string) {
	_, world, ok := command_world(dev)
	if !ok {return}
	id, component := take_word(arguments)
	if id == "" {
		console.error(dev, "Usage: inspect <entity-id> [component]")
		return
	}
	entity, found := resolve_debug_entity(dev, world, id)
	if !found {return}
	components := make(json.Object, context.temp_allocator)
	names := entity_summary(world, entity).components
	if component != "" {names = []string{component}}
	for name in names {
		value, valid := ecs.runtime_component_json(world, entity, name)
		if !valid {
			console.error(dev, fmt.tprintf("Cannot inspect component: %s", name))
			return
		}
		components[name] = value
	}
	children := make([dynamic]string, context.temp_allocator)
	for child in ecs.child_entities(world, entity) {append(&children, entity_label(world, child))}
	slice.sort(children[:])
	console.set_result(dev, struct {
		entity: Entity_Summary,
		children: []string,
		components: json.Object,
	}{entity_summary(world, entity), children[:], components})
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
	count, valid := debug_frame_count(dev, arguments, 1)
	if !valid {return}
	engine.debug.steps_remaining = count
	engine.debug.steps_requested = count
	dev.defer_reply = true
}

input_command :: proc(dev: ^console.Console, arguments: string) {
	engine, ok := command_engine(dev)
	if !ok {return}
	action, operation := take_word(arguments)
	if operation != "press" && operation != "release" && operation != "clear" {
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
	inspect_command(dev, fmt.tprintf("%s %s", id, component))
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

// Select a simulation tick only after console commands have been dispatched.
// Paused frames still sample real input, draw, poll files, and accept commands.
debug_simulation_tick :: proc(engine: ^Engine) -> bool {
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
	if engine.debug.steps_remaining > 0 {
		engine.debug.steps_remaining -= 1
		if engine.debug.steps_remaining == 0 {
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
