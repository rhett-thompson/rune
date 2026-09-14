package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import "rune:validation"
import rl "vendor:raylib"

validate_event_timeline :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_event_cases()
	assert(len(tracker.allocation_map) == 0, "marker parsing and event buffers release all owned allocations")
}

model_event_names :: proc(world: ^ecs.World, names: []string, reverse := false) {
	events := ecs.model_animation_events(world)
	assert(len(events) == len(names), fmt.tprintf("expected %d events, got %d", len(names), len(events)))
	for name, i in names {assert(events[i].name == name && events[i].reverse == reverse, name)}
}

validate_event_cases :: proc() {
	world := ecs.init()
	defer ecs.destroy(&world)
	markers := [?]assets.Model_Animation_Marker{{0, "start"}, {0.5, "hit"}, {1, "end"}}
	animator := ecs.ModelAnimator{speed = 1, loop = true}
	s := ecs.Model_Animation_State{duration = 1, playing = true}
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0)
	model_event_names(&world, {})
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.5)
	model_event_names(&world, {"start", "hit"})
	assert(s.elapsed == 0.5 && ecs.model_animation_events(&world)[1].time == 0.5)
	ecs.clear_model_animation_events(&world)
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.5)
	model_event_names(&world, {"end", "start"})
	assert(s.elapsed == 0)
	ecs.clear_model_animation_events(&world)
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.01)
	model_event_names(&world, {})
	s = {duration = 1, playing = true}
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 2.5)
	model_event_names(&world, {"start", "hit", "end", "start", "hit", "end", "start", "hit"})
	ecs.clear_model_animation_events(&world)
	s = {duration = 1, elapsed = 1, playing = true}
	animator.speed = -1
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.5)
	model_event_names(&world, {"end", "hit"}, true)
	ecs.clear_model_animation_events(&world)
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.5)
	model_event_names(&world, {"start", "end"}, true)
	assert(s.elapsed == 1)
	ecs.clear_model_animation_events(&world)
	animator.speed = 1
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.01)
	model_event_names(&world, {}) // Reversing at the seam must not repeat either endpoint.
	animator.speed = -1
	s = {duration = 1, elapsed = 1, playing = true, markers_started = true, marker_boundary_crossed = true}
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.01)
	model_event_names(&world, {})
	// Reverse from a seek to zero wraps immediately, but never replays zero.
	s = {duration = 1, elapsed = 0, playing = true, markers_started = true}
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.1)
	model_event_names(&world, {"end"}, true)
	ecs.clear_model_animation_events(&world)
	animator.loop = false
	s = {duration = 1, elapsed = 1, playing = true}
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 3)
	model_event_names(&world, {"end", "hit", "start"}, true)
	assert(s.finished && !s.playing && s.elapsed == 0)
	ecs.clear_model_animation_events(&world)
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 3)
	model_event_names(&world, {})
	animator.speed = 4
	s = {duration = 1, playing = true}
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.25)
	model_event_names(&world, {"start", "hit", "end"})
	assert(s.finished && s.elapsed == 1)
	ecs.clear_model_animation_events(&world)
	// Speed reversal at a marker does not duplicate that marker.
	s = {duration = 1, elapsed = 0.5, playing = true, markers_started = true}
	animator.speed = -1
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 0.1)
	model_event_names(&world, {})
	// Pausing preserves traversal and leaves a fresh update's buffer empty.
	s.playing = false
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 10)
	model_event_names(&world, {})
	// Huge finite advances stay bounded and still compute a valid final pose.
	animator = {speed = 1e30, loop = true}
	s = {duration = 1, playing = true}
	bridge.advance_model_timeline(&world, 1, "robot.glb", "walk", &s, animator, markers[:], 1)
	assert(len(ecs.model_animation_events(&world)) == ecs.MAX_MODEL_ANIMATION_EVENTS)
	assert(ecs.model_animation_events_overflowed(&world) && s.elapsed >= 0 && s.elapsed <= 1)
	ecs.clear_model_animation_events(&world)
	assert(!ecs.model_animation_events_overflowed(&world))
	assert(ecs.append_sprite_animation_event(&world, {name = "sprite"}))
	assert(ecs.append_model_animation_event(&world, {name = "model"}))
	ecs.clear_sprite_animation_events(&world)
	model_event_names(&world, {"model"})
	validate_marker_files()
}

validate_marker_files :: proc() {
	path :: "build/model-marker-parsing.model-events.json"
	defer os.remove(path)
	invalid := []string{
		`null`, `{}`, `{"clips":[]}`, `{"clips":{"":[]}}`, `{"clips":{"walk":{}}}`,
		`{"clips":{"walk":[],"":[]}}`,
		`{"clips":{"walk":[{"time":-1,"name":"bad"}]}}`,
		`{"clips":{"walk":[{"time":0,"name":""}]}}`,
		`{"clips":{"walk":[{"name":"missing"}]}}`,
		`{"clips":{"walk":[{"time":1,"name":"later"},{"time":0,"name":"earlier"}]}}`,
		`{"clips":{"walk":[{"time":0,"name":"bad","callback":"eval"}]}}`,
	}
	for source in invalid {
		assert(os.write_entire_file(path, source) == nil)
		data, error := assets.load_model_events_data(path)
		assert(error != "" && len(data.clips) == 0, fmt.tprintf("%s: error=%s tracks=%d", source, error, len(data.clips)))
	}
	assert(os.write_entire_file(path, `{"clips":{"walk":[{"time":0,"name":"footstep"},{"time":0,"name":"dust"}]}}`) == nil)
	data, error := assets.load_model_events_data(path)
	assert(error == "" && len(data.clips["walk"]) == 2 && data.clips["walk"][1].name == "dust")
	assets.destroy_model_events_data(&data)
}

validate_model_marker_runtime :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity, registry: ^ecs.Component_Registry) {
	path :: "../../build/model-marker-runtime.model-events.json"
	output :: "build/model-marker-runtime.model-events.json"
	source :: `{"clips":{"bend":[{"time":0,"name":"start"},{"time":0.5,"name":"footstep"},{"time":1,"name":"impact"},{"time":2,"name":"end"}],"sway":[{"time":0.5,"name":"projectile"}]}}`
	assert(os.write_entire_file(output, source) == nil)
	defer os.remove(output)
	for e in ecs.entities_with_component(world, "ModelAnimator") {if e != entity {ecs.set_enabled(world, e, false)}}
	animator, _ := ecs.get_model_animator(world, entity)
	animator.events, animator.speed, animator.loop = path, 1, true
	assert(ecs.set_model_animator(world, entity, animator))
	assert(ecs.play_model_animation(world, entity, "bend"))
	bridge.update_animations(ctx, world, manager, 0.5)
	model_event_names(world, {"start", "footstep"})
	assert(ecs.model_animation_events(world)[0].model == Model)
	for _ in 0 ..< 2 {
		rl.BeginDrawing()
		bridge.draw_scene(ctx, world, manager)
		rl.EndDrawing()
	}
	model_event_names(world, {"start", "footstep"})
	assert(ecs.pause_model_animation(world, entity))
	bridge.update_animations(ctx, world, manager, 2)
	model_event_names(world, {})
	assert(ecs.seek_model_animation(world, entity, 1))
	bridge.update_animations(ctx, world, manager, 0)
	model_event_names(world, {})
	assert(ecs.resume_model_animation(world, entity))
	bridge.update_animations(ctx, world, manager, 0.1)
	model_event_names(world, {})
	assert(ecs.play_model_animation(world, entity, "bend"))
	bridge.update_animations(ctx, world, manager, 4.5)
	model_event_names(world, {"start", "footstep", "impact", "end", "start", "footstep", "impact", "end", "start", "footstep"})
	assert(ecs.transition_model_animation(world, entity, "sway", 1))
	bridge.update_animations(ctx, world, manager, 0.5)
	model_event_names(world, {"projectile"})
	assert(len(ctx.animation_players[entity].blend_pose) > 0, "only the destination emits during a blend")
	animator, _ = ecs.get_model_animator(world, entity)
	animator.speed = -1
	assert(ecs.set_model_animator(world, entity, animator))
	assert(ecs.play_model_animation(world, entity, "bend"))
	bridge.update_animations(ctx, world, manager, 1.5)
	model_event_names(world, {"end", "impact", "footstep"}, true)
	// Reload text while a buffer is retained. Playback position is preserved.
	assert(os.write_entire_file(output, `{"clips":{"bend":[{"time":0,"name":"new_start"}]}}`) == nil)
	stale := manager.model_events[path]
	stale.modified_time = -2
	manager.model_events[path] = stale
	assets.refresh_animations(manager)
	model_event_names(world, {"end", "impact", "footstep"}, true)
	bridge.update_animations(ctx, world, manager, 0.5)
	model_event_names(world, {"new_start"}, true)
	assert(os.write_entire_file(output, `{"clips":{"bend":[{"time":-1,"name":"invalid"}]}}`) == nil)
	stale = manager.model_events[path]
	stale.modified_time = -2
	manager.model_events[path] = stale
	assets.refresh_animations(manager)
	assert(manager.model_events[path].revision == 2, "invalid replacement retains the working marker track")
	report := validation.init_report()
	validation.validate_model_events_reference(&report, Scene, "ModelAnimator.events", parse(fmt.tprintf("%q", path)), Root)
	assert(!validation.is_valid(&report) && strings.contains(report.diagnostics[0].message, "$.clips.bend[0].time"))
	validation.destroy_report(&report)
	assert(ecs.set_runtime_field(world, registry, entity, "ModelAnimator", "events", parse(`""`)))
	bridge.update_animations(ctx, world, manager, 3)
	model_event_names(world, {})
}
