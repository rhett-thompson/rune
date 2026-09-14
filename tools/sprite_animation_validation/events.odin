package main

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:render"
import "rune:validation"

validate_events :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_event_cases()
	assert(len(tracker.allocation_map) == 0, "event buffers, marker JSON, reloads, and World destruction release all allocations")
}

validate_event_cases :: proc() {
	world := ecs.init()
	defer ecs.destroy(&world)
	frames := [?]i32{9, 4, 4, 7}
	markers := [?]assets.Animation_Marker{{0, "start"}, {1, "footstep"}, {1, "dust"}, {3, "hit"}}
	clip := assets.Animation_Clip{frames = frames[:], markers = markers[:], fps = 4, loop = true}
	animator := ecs.SpriteAnimator{animation = "test.animation.json", clip = "run", autoplay = true, speed = 1}
	state: ecs.Sprite_Animation_State
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 0)
	expect_events(&world, {})
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 0.25)
	expect_events(&world, {"start", "footstep", "dust"})
	event := ecs.sprite_animation_events(&world)[1]
	assert(event.entity == 1 && event.frame == 1 && event.clip == "run" && event.animation == animator.animation)
	ecs.clear_sprite_animation_events(&world)
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 2)
	expect_events(&world, {"hit", "start", "footstep", "dust", "hit", "start", "footstep", "dust"})
	assert(state.frame == 1)
	ecs.clear_sprite_animation_events(&world)
	state.playing = false
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 5)
	expect_events(&world, {})
	state.playing = true
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 0.5)
	expect_events(&world, {"hit"})
	ecs.clear_sprite_animation_events(&world)
	clip.loop = false
	state = {}
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 20)
	expect_events(&world, {"start", "footstep", "dust", "hit"})
	assert(state.finished && !state.playing && state.frame == 3)
	ecs.clear_sprite_animation_events(&world)
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 20)
	expect_events(&world, {})
	// A speed change preserves fractional progress, and events use clip positions.
	state = {}
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 0.125)
	expect_events(&world, {"start"})
	ecs.clear_sprite_animation_events(&world)
	animator.speed = 2
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 0.0625)
	expect_events(&world, {"footstep", "dust"})
	assert(state.frame == 1)
	// Reload resets marker traversal, but paused reloads cannot emit events.
	ecs.clear_sprite_animation_events(&world)
	state.playing = false
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 2, 1)
	expect_events(&world, {})
	state.playing = true
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 2, 0.01)
	expect_events(&world, {"start"})
	ecs.clear_sprite_animation_events(&world)
	animator.speed = 0
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 2, 1)
	expect_events(&world, {})
	animator.speed = transmute(f32)u32(0x7f800000)
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 2, 1)
	expect_events(&world, {})
	// Extreme valid speed is bounded without overflowing integer frame arithmetic.
	clip.loop = true
	state = {}
	animator.speed = 1e30
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 1)
	assert(len(ecs.sprite_animation_events(&world)) == ecs.MAX_SPRITE_ANIMATION_EVENTS)
	assert(ecs.sprite_animation_events_overflowed(&world))
	assert(state.frame >= 0 && state.frame < 4)
	ecs.clear_sprite_animation_events(&world)
	assert(!ecs.sprite_animation_events_overflowed(&world))
	// Single-frame clips emit their initial marker once, even when they finish.
	clip.frames = frames[:1]
	clip.markers = markers[:1]
	clip.loop = false
	animator.speed = 1
	state = {}
	render.advance_sprite_animation(&world, 1, animator, &state, clip, 1, 1)
	expect_events(&world, {"start"})
	assert(state.finished)
	// Quotient/remainder rounding must not turn an exact cycle into an extra
	// crossed frame on the following small update (1 / 0.1 versus fmod).
	state = {playing = true}
	render.advance_animation_state(&state, 4, 10, true, 1, 1)
	assert(state.frame == 2)
	render.advance_animation_state(&state, 4, 10, true, 1, 0.01)
	assert(state.frame == 2)
	validate_marker_json()
	validate_marker_reload()
}

expect_events :: proc(world: ^ecs.World, names: []string) {
	events := ecs.sprite_animation_events(world)
	assert(len(events) == len(names))
	for name, index in names {assert(events[index].name == name)}
}

validate_marker_json :: proc() {
	invalid_sources := []string{
		`null`, `{}`, `[{}]`, `[{"frame":-1,"name":"bad"}]`,
		`[{"frame":4,"name":"bad"}]`, `[{"frame":0.5,"name":"bad"}]`,
		`[{"frame":1.000000001,"name":"bad"}]`,
		`[{"frame":0,"name":""}]`, `[{"frame":0,"name":12}]`,
		`[{"frame":0,"name":"bad","action":"code"}]`,
		`[{"frame":2,"name":"late"},{"frame":1,"name":"early"}]`,
	}
	for source in invalid_sources {
		value: json.Value
		assert(json.unmarshal(transmute([]u8)source, &value) == nil)
		markers, error := assets.decode_animation_markers(value, 4)
		assert(error != "" && len(markers) == 0)
		json.destroy_value(value)
	}
	value: json.Value
	assert(json.unmarshal(transmute([]u8)string(`[{"frame":0,"name":"step"},{"frame":0,"name":"dust"}]`), &value) == nil)
	markers, error := assets.decode_animation_markers(value, 4)
	assert(error == "" && len(markers) == 2)
	json.destroy_value(value)
	assert(markers[1].name == "dust", "marker names outlive parsed JSON")
	assets.destroy_animation_markers(markers)
}

validate_marker_reload :: proc() {
	path :: "build/marker-validation.animation.json"
	source :: `{"texture":"unused.png","frame_size":[1,1],"clips":{"run":{"frames":[0,1],"markers":[{"frame":0,"name":"old"}]}}}`
	assert(os.write_entire_file(path, source) == nil)
	defer os.remove(path)
	manager := assets.Asset_Manager{
		animations = make(map[string]assets.Animation_Asset),
		retained_paths = make(map[string]string),
		diagnostics = assets.init_diagnostic_log(),
	}
	manager.root = assets.retain_path(&manager, "build")
	defer assets.shutdown(&manager)
	data, revision, loaded := assets.animation(&manager, "marker-validation.animation.json")
	assert(loaded && revision == 1)
	world := ecs.init()
	defer ecs.destroy(&world)
	state: ecs.Sprite_Animation_State
	animator := ecs.SpriteAnimator{animation = "marker-validation.animation.json", clip = "run", autoplay = true, speed = 1}
	render.advance_sprite_animation(&world, 1, animator, &state, data.clips["run"], revision, 0.01)
	expect_events(&world, {"old"})
	assert(os.write_entire_file(path, `{"texture":"unused.png","frame_size":[1,1],"clips":{"run":{"frames":[0,1],"markers":[{"frame":9,"name":"bad"}]}}}`) == nil)
	stale := manager.animations["marker-validation.animation.json"]
	stale.modified_time = -2
	manager.animations["marker-validation.animation.json"] = stale
	assets.refresh_animations(&manager)
	data, revision, loaded = assets.animation(&manager, "marker-validation.animation.json")
	assert(loaded && revision == 1 && data.clips["run"].markers[0].name == "old")
	report := validation.init_report()
	validation.validate_animation(&report, path, "build")
	found := false
	for diagnostic in report.diagnostics {
		if diagnostic.path == "$.clips.run.markers" && strings.contains(diagnostic.message, "[0].frame") {found = true}
	}
	assert(found, "project validator identifies invalid marker location")
	validation.destroy_report(&report)
	replacement, _ := strings.replace_all(source, "old", "new")
	defer delete(replacement)
	assert(os.write_entire_file(path, transmute([]u8)replacement) == nil)
	assets.refresh_animations(&manager)
	data, revision, loaded = assets.animation(&manager, "marker-validation.animation.json")
	assert(loaded && revision == 2)
	expect_events(&world, {"old"}) // The prior asset was freed; buffered text survives.
	ecs.clear_sprite_animation_events(&world)
	render.advance_sprite_animation(&world, 1, animator, &state, data.clips["run"], revision, 0.01)
	expect_events(&world, {"new"})
}

// Called with a hidden graphics context by --runtime. Exercise the actual
// asset/World pipeline, controls, queue, component edits, and entity lifetime.
validate_runtime_markers :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world := ecs.init()
	defer ecs.destroy(&world)
	manager := assets.init("examples/animation_events_2d")
	defer assets.shutdown(&manager)
	entity := ecs.create_entity(&world)
	sprite_json: json.Value
	assert(json.unmarshal(transmute([]u8)string(`{}`), &sprite_json) == nil)
	defer json.destroy_value(sprite_json)
	assert(ecs.add_component(&world, &registry, entity, "SpriteRenderer", sprite_json))
	animator_json: json.Value
	assert(json.unmarshal(transmute([]u8)string(`{"animation":"animations/knight.animation.json","clip":"run","autoplay":true,"speed":1}`), &animator_json) == nil)
	defer json.destroy_value(animator_json)
	assert(ecs.add_component(&world, &registry, entity, "SpriteAnimator", animator_json))
	render.update_sprite_animators(&world, &manager, 0.01)
	expect_events(&world, {"footstep"})
	assert(ecs.play_sprite_animation(&world, entity, "run", restart = false))
	render.update_sprite_animators(&world, &manager, 0.01)
	expect_events(&world, {})
	assert(ecs.pause_sprite_animation(&world, entity))
	render.update_sprite_animators(&world, &manager, 2)
	expect_events(&world, {})
	assert(ecs.resume_sprite_animation(&world, entity))
	render.update_sprite_animators(&world, &manager, 0.5)
	expect_events(&world, {"footstep"})
	assert(ecs.stop_sprite_animation(&world, entity))
	render.update_sprite_animators(&world, &manager, 2)
	expect_events(&world, {})
	assert(ecs.resume_sprite_animation(&world, entity))
	render.update_sprite_animators(&world, &manager, 0.01)
	expect_events(&world, {"footstep"})
	assert(ecs.set_enabled(&world, entity, false))
	render.update_sprite_animators(&world, &manager, 2)
	expect_events(&world, {})
	assert(ecs.set_enabled(&world, entity, true))
	assert(ecs.play_sprite_animation(&world, entity, "strike"))
	assert(ecs.queue_sprite_animation(&world, entity, "run"))
	render.update_sprite_animators(&world, &manager, 2)
	expect_events(&world, {"impact"})
	render.update_sprite_animators(&world, &manager, 0.01)
	expect_events(&world, {"footstep"})
	assert(ecs.play_sprite_animation(&world, entity, "run"))
	render.update_sprite_animators(&world, &manager, 0.01)
	expect_events(&world, {"footstep"})
	// Console/typed component edits share the reset path.
	assert(ecs.set_runtime_field(&world, &registry, entity, "SpriteAnimator", "clip", json.String("strike")))
	render.update_sprite_animators(&world, &manager, 0.3)
	expect_events(&world, {"impact"})
	assert(ecs.remove_component(&world, entity, "SpriteAnimator"))
	expect_events(&world, {"impact"}) // A historical event remains safe to inspect.
	render.update_sprite_animators(&world, &manager, 2)
	expect_events(&world, {})
	assert(ecs.add_component(&world, &registry, entity, "SpriteAnimator", animator_json))
	render.update_sprite_animators(&world, &manager, 0.01)
	expect_events(&world, {"footstep"})
	assert(ecs.destroy_entity(&world, entity))
	assert(!ecs.is_alive(&world, ecs.sprite_animation_events(&world)[0].entity))
	render.update_sprite_animators(&world, &manager, 1)
	expect_events(&world, {})
}
