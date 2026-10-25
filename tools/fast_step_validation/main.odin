package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

Case_Kind :: enum {Cadence, Capture_Profile, Restore_Cap, Change_Cap, Interrupt, Quit_Prefix, Vsync, Save_Boundary}
Case_State :: struct {
	kind: Case_Kind,
	scene_loop, fast: bool,
	count: int,
	fixed, updates, post_physics, post_animation, ui_frames, draws: int,
	pressed, held: int,
	value: i64,
	first_frame, last_frame: u64,
	first_tick_time, last_tick_time, fast_frame_ms: f64,
	expected_cap: i32,
	restored_frame_ms: f32,
	before_saves: int,
	checked, shutdown_checked: bool,
	reply_path: string,
}
active: ^Case_State

observe_tick :: proc(game: ^rune.Engine) {
	state := active
	assert(game.delta_time == game.fixed_delta_time)
	assert(game.window.step_uncapped == state.fast)
	assert(rl.IsWindowState({.VSYNC_HINT}) == (state.kind == .Vsync))
	assert(state.updates < state.count, "fast stepping must not overshoot its requested count")
	if state.updates == 0 {state.first_frame = game.debug.frame; state.first_tick_time = rl.GetTime()}
	state.last_frame = game.debug.frame
	state.last_tick_time = rl.GetTime()
	state.updates += 1
	state.value += 7
	if input.pressed(&game.input, "fire") {state.pressed += 1}
	if input.is_down(&game.input, "fire") {state.held += 1}
	if state.kind == .Change_Cap && state.updates == 1 {
		assert(game.window.step_uncapped && game.window.target_fps == 60)
		assert(rune.set_target_fps(game, 30))
		assert(game.window.target_fps == 30 && game.window.step_uncapped)
	}
	if state.kind == .Interrupt && state.updates == 3 {rune.request_exit(game)}
	if state.kind == .Save_Boundary {
		if state.updates == 3 {assert(rune.request_save(game, "checkpoint"))}
		if state.updates == 4 {
			assert(game.debug.frame == state.first_frame+1)
			assert(game.save_request.action == .None && game.save_result.sequence == 1 && game.save_result.ok)
			assert(state.before_saves == 1, "queued saves must finish before another simulation tick")
		}
	}
}

callback_update :: proc(game: ^rune.Engine) {observe_tick(game)}
scene_fixed :: proc(game: ^rune.Engine, world: ^ecs.World) {
	assert(active.fixed == active.updates)
	active.fixed += 1
	active.value += 3
}
scene_post_physics :: proc(game: ^rune.Engine, world: ^ecs.World) {
	assert(active.fixed == active.post_physics + 1)
	active.post_physics += 1
}
scene_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	assert(active.fixed == active.updates + 1 && active.fixed == active.post_physics)
	observe_tick(game)
}
scene_post_animation :: proc(game: ^rune.Engine, world: ^ecs.World) {
	assert(active.updates == active.post_animation + 1)
	active.post_animation += 1
	active.value += 5
}
scene_ui :: proc(game: ^rune.Engine, world: ^ecs.World) {active.ui_frames += 1}
scene_before_save :: proc(game: ^rune.Engine, world: ^ecs.World) {
	assert(active.kind == .Save_Boundary && active.updates == 3)
	assert(game.debug.frame == active.first_frame+1)
	active.before_saves += 1
}
draw :: proc(game: ^rune.Engine) {
	assert(game.debug.frame < 1000, "validator exceeded its frame bound")
	active.draws += 1
	rl.DrawRectangle(20, 20, 30, 30, {200, 80, 40, 255})
}
scene_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {draw(game)}
scene_shutdown :: proc(game: ^rune.Engine, world: ^ecs.World) {
	assert(!game.window.step_uncapped && game.window.target_fps == active.expected_cap)
	assert(game.console.remote.batch == nil && !game.console.defer_reply)
	assert(os.exists(active.reply_path), "the batch reply must precede scene shutdown callbacks")
	active.shutdown_checked = true
}

check_command :: proc(dev: ^console.Console, arguments: string) {
	game := cast(^rune.Engine)dev.user_data
	assert(active.updates == active.count && !dev.defer_reply)
	assert(!game.window.step_uncapped && game.window.target_fps == active.expected_cap)
	assert(game.project.window.target_fps == 0, "runtime pacing must not mutate project settings")
	assert(rl.IsWindowState({.VSYNC_HINT}) == (active.kind == .Vsync), "fast stepping must preserve V-Sync")
	active.checked = true
	console.set_result(dev, struct {updates: int, frame: u64, cap: i32}{active.updates, game.debug.frame, game.window.target_fps})
}

run_case :: proc(project, directory: string, scene_loop, fast: bool, count: int, kind: Case_Kind) -> i64 {
	state := Case_State{scene_loop=scene_loop, fast=fast, count=count, kind=kind}
	active = &state
	name := fmt.tprintf("%s-%s-%d-%v", "scene" if scene_loop else "callbacks", "fast" if fast else "plain", count, kind)
	fmt.printf("RUN fast-step %s\n", name)
	inbox := fmt.tprintf("%s/%s", directory, name)
	assert(os.make_directory(inbox) == nil)
	defer os.remove(inbox)
	request := fmt.tprintf("%s/request.batch", inbox)
	defer os.remove(request)
	state.reply_path = fmt.tprintf("%s/request.result.json", inbox)
	defer os.remove(state.reply_path)
	capture := fmt.tprintf("%s/frame.png", inbox)
	defer os.remove(capture)
	checkpoint := fmt.tprintf("%s/checkpoint.save.json", inbox)
	defer os.remove(checkpoint)
	game, loaded := rune.init(project, defer_window_show=true)
	assert(loaded)
	defer rune.shutdown(&game)
	game.debug.paused = true
	if kind == .Vsync {rl.SetWindowState({.VSYNC_HINT})}
	if kind == .Save_Boundary {
		assert(scene_loop)
		assert(rune.configure_saves(&game, {game_id="rune-fast-step-validation", game_version=1, directory=inbox}))
		assert(rune.load_active_scene(&game, "empty.scene.json"))
	}
	if kind == .Restore_Cap || kind == .Change_Cap || kind == .Interrupt {
		assert(rune.set_target_fps(&game, 60))
		state.expected_cap = 30 if kind == .Change_Cap else 60
	}
	assert(input.inject_action(&game.input, "fire", true))
	assert(console.register(&game.console, "validate_step", "Validate completed simulation", check_command))
	assert(console.enable_remote(&game.console, inbox))
	step := fmt.tprintf("step %s%d", "--fast " if fast else "", count)
	commands := fmt.tprintf("%s\nvalidate_step\nquit", step)
	if kind == .Capture_Profile {
		commands = fmt.tprintf("%s\nwindow show\ncapture %s\nwindow hidden\nprofile 3\nvalidate_step\nquit", step, capture)
	} else if kind == .Restore_Cap || kind == .Change_Cap {
		commands = fmt.tprintf("%s\nprofile 12\nvalidate_step\nquit", step)
	} else if kind == .Quit_Prefix {
		commands = fmt.tprintf("%s\nquit\nvalidate_step", step)
	}
	assert(os.write_entire_file(request, commands) == nil)
	if scene_loop {
		assert(rune.register_system(&game, rune.System{
			name="fast-step-validation", fixed_update=scene_fixed, post_physics=scene_post_physics,
			update=scene_update, post_animation=scene_post_animation, ui_update=scene_ui,
			draw=scene_draw, shutdown=scene_shutdown, before_save=scene_before_save,
		}))
		if kind == .Save_Boundary {assert(rune.run_project(&game))}
		else {world := ecs.init(); rune.run_scene(&game, &world)}
		assert(state.shutdown_checked)
	} else {rune.run_callbacks(&game, callback_update, draw)}
	assert(!game.is_running && game.console.remote.batch == nil && !game.console.defer_reply)
	assert(!game.window.step_uncapped && game.window.target_fps == state.expected_cap)
	assert(!os.exists(request))
	bytes, read_error := os.read_entire_file(state.reply_path, context.temp_allocator)
	assert(read_error == nil)
	reply: console.Remote_Batch_Result
	assert(json.unmarshal(bytes, &reply, allocator=context.temp_allocator) == nil)
	actual := 3 if kind == .Interrupt else count
	assert(state.updates == actual && state.held == actual && state.pressed == 1)
	assert(game.debug.simulation_updates == u64(actual) && game.debug.fixed_steps == u64(actual))
	assert(math.abs(game.debug.simulation_time - f64(actual)*f64(game.fixed_delta_time)) < 0.000001)
	if scene_loop {
		assert(state.fixed == actual && state.post_physics == actual && state.post_animation == actual)
		assert(state.value == i64(actual)*15 && state.ui_frames == state.draws)
	} else {assert(state.value == i64(actual)*7)}
	if kind == .Interrupt {
		assert(state.last_frame == state.first_frame, "exit must stop additional ticks within the frame")
		assert(!reply.ok && !reply.complete && reply.completed == 1 && reply.requested == 3)
		assert(!reply.results[0].ok && !state.checked)
		assert(strings.contains(strings.join(reply.results[0].lines, "\n", context.temp_allocator), "Engine stopped before the command completed."))
	} else {
		simulation_frames := (count+7)/8 if fast else count
		if kind == .Save_Boundary {
			simulation_frames = 1+(count-3+7)/8
			assert(state.before_saves == 1 && os.exists(checkpoint))
		}
		assert(state.last_frame-state.first_frame+1 == u64(simulation_frames))
		assert(reply.results[0].ok && reply.results[0].command == step)
		assert(reply.results[0].data.(json.Object)["simulation_updates"].(json.Integer) == i64(count))
		if kind == .Quit_Prefix {
			assert(!reply.ok && !reply.complete && reply.completed == 2 && reply.requested == 3 && !state.checked)
			assert(reply.results[1].data.(json.Object)["exit_requested"].(json.Boolean))
			assert(state.draws == simulation_frames)
		} else {
			assert(reply.ok && reply.complete && state.checked)
			extra_frames := 1
			if kind == .Capture_Profile {
				extra_frames = 7
				assert(reply.completed == 7)
				assert(!reply.results[1].data.(json.Object)["hidden"].(json.Boolean))
				assert(reply.results[1].data.(json.Object)["requested_mode"].(json.String) == "windowed")
				capture_data := reply.results[2].data.(json.Object)
				assert(capture_data["metadata"].(json.Object)["frame"].(json.Integer) == i64(simulation_frames+2))
				assert(reply.results[3].data.(json.Object)["hidden"].(json.Boolean))
				assert(reply.results[3].data.(json.Object)["requested_mode"].(json.String) == "windowed")
				assert(reply.results[4].data.(json.Object)["frames"].(json.Integer) == 3)
				path_c, _ := strings.clone_to_cstring(capture, context.temp_allocator)
				image := rl.LoadImage(path_c)
				assert(image.data != nil && image.width == 320 && image.height == 240)
				assert(rl.GetImageColor(image, 25, 25) == rl.Color{200, 80, 40, 255})
				rl.UnloadImage(image)
			} else if kind == .Restore_Cap || kind == .Change_Cap {
				extra_frames = 13
				assert(reply.completed == 4)
				profile := reply.results[1].data.(json.Object)
				assert(profile["frames"].(json.Integer) == 12)
				mean, ok := ecs.read_number(profile["frame"].(json.Object)["mean_ms"])
				assert(ok && mean >= 0.8*1000/f32(state.expected_cap), "restored cap must pace actual EndDrawing frames")
				state.restored_frame_ms = mean
				assert(state.last_frame > state.first_frame)
				state.fast_frame_ms = 1000*(state.last_tick_time-state.first_tick_time)/f64(state.last_frame-state.first_frame)
				assert(state.fast_frame_ms < 0.9*1000/60, "native frame cap must remain lifted throughout fast stepping")
			} else {assert(reply.completed == 3)}
			assert(state.draws == simulation_frames+extra_frames)
		}
	}
	fmt.printf("PASS fast-step %s: ticks=%d simulation_frames=%d draws=%d restored_cap=%d restored_frame_ms=%.3f fast_frame_ms=%.3f\n", name, actual,
		state.last_frame-state.first_frame+1, state.draws, state.expected_cap, state.restored_frame_ms, state.fast_frame_ms)
	return state.value
}

main :: proc() {
	runtime := false
	for argument in os.args[1:] {if argument == "--runtime" {runtime = true}}
	if !runtime {fmt.println("Fast-step runtime validation requires --runtime (briefly reveals capture cases)."); return}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	assert(os.make_directory_all("build") == nil || os.exists("build"))
	directory, err := os.make_directory_temp("build", "fast-step-validation-*", context.temp_allocator)
	assert(err == nil)
	defer os.remove(directory)
	project := fmt.tprintf("%s/project.json", directory)
	defer os.remove(project)
	controls := fmt.tprintf("%s/input.json", directory)
	defer os.remove(controls)
	scene := fmt.tprintf("%s/empty.scene.json", directory)
	defer os.remove(scene)
	assert(os.write_entire_file(project, `{"name":"Fast step validation","window":{"width":320,"height":240,"target_fps":0,"vsync":false,"hidden":true},"input":"input.json","background_color":[20,40,80,255],"hot_reload":{"enabled":false}}`) == nil)
	assert(os.write_entire_file(controls, `{"actions":{"fire":[{"type":"keyboard","key":"SPACE"}]},"axes":{}}`) == nil)
	assert(os.write_entire_file(scene, `{"name":"Empty validation scene","entities":[]}`) == nil)
	for scene_loop in ([2]bool{false, true}) {
		for count in ([5]int{1, 7, 8, 9, 600}) {
			plain := run_case(project, directory, scene_loop, false, count, .Cadence)
			fast := run_case(project, directory, scene_loop, true, count, .Cadence)
			assert(plain == fast, "controlled simulation state must agree across plain and fast stepping")
		}
		for kind in ([5]Case_Kind{.Capture_Profile, .Restore_Cap, .Change_Cap, .Quit_Prefix, .Vsync}) {
			count := 600 if kind == .Restore_Cap || kind == .Change_Cap else 9
			run_case(project, directory, scene_loop, true, count, kind)
		}
		run_case(project, directory, scene_loop, true, 600, .Interrupt)
	}
	run_case(project, directory, true, true, 16, .Save_Boundary)
	fmt.println("Fast-step runtime validation passed: 33 real loop cases, tick cadence, injected edges, batch/capture/profile ordering, pacing restoration, V-Sync, queued saves and interruption")
}
