package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "rune:ecs"
import "rune:scene"
import "rune:validation"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

parse :: proc(text: string) -> json.Value {
	data: json.Value
	assert(json.unmarshal(transmute([]u8)text, &data, allocator = context.temp_allocator) == nil)
	return data
}

validate_data :: proc(registry: ^ecs.Component_Registry) {
	defaults, ok := ecs.post_processing_from_json(parse("{}"))
	assert(ok && defaults == ecs.default_post_processing())
	partial, valid := ecs.post_processing_from_json(parse(`{"bloom":{"mode":"additive"},"tonemap":{"exposure":2}}`))
	assert(valid && partial.bloom.intensity == 0.05 && partial.bloom.levels == 0.5 && partial.tonemap.white == 1)
	assert(partial.bloom.mode == .additive && partial.tonemap.exposure == 2)
	for bad in ([]string{
		`{"bloom":{"mode":"ADDITIVE"}}`, `{"bloom":{"mode":2}}`, `{"bloom":{"intensity":-1}}`,
		`{"bloom":{"levels":1.01}}`, `{"bloom":{"typo":1}}`, `{"ssao":{"sample_count":0}}`,
		`{"ssao":{"sample_count":1.5}}`, `{"ssao":{"sample_count":2147483648}}`,
		`{"ssao":{"radius":0}}`, `{"ssr":{"max_ray_steps":257}}`, `{"dof":{"focus_scale":0}}`,
		`{"fog":{"start":5,"end":4}}`, `{"fog":{"color":[256,0,0,255]}}`,
		`{"fog":{"color":[0.5,0,0,255]}}`, `{"auto_exposure":{"min_ev":3,"max_ev":2}}`,
		`{"anti_aliasing":"msaa"}`, `{"enabled":null}`, `{"bloom":null}`,
		`{"tonemap":{"exposure":null}}`, `{"ssao":{"enabled":1}}`, `{"unknown":1}`,
	}) {
		_, accepted := ecs.post_processing_from_json(parse(bad))
		assert(!accepted, bad)
	}
	w := ecs.init()
	defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	assert(ecs.add(&w, registry, e, partial))
	data, serialized := ecs.runtime_component_json(&w, e, "PostProcessing")
	assert(serialized)
	roundtrip, roundtrip_ok := ecs.post_processing_from_json(data)
	assert(roundtrip_ok && roundtrip == partial, "nested modes must serialize as lowercase strings")
	assert(ecs.set_runtime_field(&w, registry, e, "PostProcessing", "bloom.intensity", json.Float(0.3)))
	current, _ := ecs.get(&w, e, ecs.PostProcessing)
	assert(current.bloom.intensity == 0.3 && current.bloom.mode == .additive)
	assert(!ecs.set_runtime_field(&w, registry, e, "PostProcessing", "tonemap.white", json.Integer(0)))
	unchanged, _ := ecs.get(&w, e, ecs.PostProcessing)
	assert(unchanged == current, "failed writes must preserve the runtime profile")
	current.ssao.radius = math.nan_f32()
	assert(!ecs.set(&w, e, current) && !ecs.add(&w, registry, e, current))
	current = partial
	current.anti_aliasing = ecs.Post_Anti_Aliasing(99)
	assert(!ecs.set(&w, e, current))
	assert(ecs.remove_component(&w, e, "PostProcessing"))
	_, remains := ecs.get(&w, e, ecs.PostProcessing)
	assert(!remains)
	assert(ecs.add(&w, registry, e, defaults))
	assert(ecs.destroy_entity(&w, e) && len(w.post_processing) == 0)
}

validate_selection :: proc(registry: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	global_a, global_b, camera_a, camera_b, parent := ecs.create_entity(&w), ecs.create_entity(&w),
		ecs.create_entity(&w), ecs.create_entity(&w), ecs.create_entity(&w)
	for e, i in ([]ecs.Entity{global_a, global_b, camera_a, camera_b}) {
		value := ecs.default_post_processing()
		value.tonemap.exposure = f32(i+1)
		assert(ecs.add(&w, registry, e, value))
	}
	for camera in ([]ecs.Entity{camera_a, camera_b}) {
		assert(ecs.add_component(&w, registry, camera, "Camera3D", parse("{}")))
	}
	value, found := ecs.active_post_processing(&w, 0)
	assert(found && value.tonemap.exposure == 1, "global ties use lowest handle")
	value, found = ecs.active_post_processing(&w, camera_b)
	assert(found && value.tonemap.exposure == 4, "active camera overrides scene")
	assert(ecs.set_enabled(&w, camera_b, false))
	value, found = ecs.active_post_processing(&w, camera_b)
	assert(found && value.tonemap.exposure == 1, "inactive camera A must not become global")
	assert(ecs.set_parent(&w, global_a, parent))
	assert(ecs.set_enabled(&w, parent, false))
	value, found = ecs.active_post_processing(&w, 0)
	assert(found && value.tonemap.exposure == 2)
	value.enabled = false
	assert(ecs.set(&w, global_b, value))
	_, found = ecs.active_post_processing(&w, 0)
	assert(!found)
}

validate_reload :: proc(registry: ^ecs.Component_Registry) {
	path :: "examples/post_processing_3d/scenes/main.scene.json"
	w, ok := scene.load(path, registry)
	assert(ok, scene.last_load_error())
	defer ecs.destroy(&w)
	snapshot, loaded := scene.load("tools/post_processing_validation/fixtures/reload.scene.json", registry)
	assert(loaded, scene.last_load_error())
	defer ecs.destroy(&snapshot)
	e, found := ecs.find_entity_by_id(&w, "post")
	assert(found)
	// A minimal independent fixture exercises value-only reload and nested enums.
	other, other_ok := scene.load("tools/post_processing_validation/fixtures/reload.scene.json", registry)
	assert(other_ok)
	target, _ := ecs.find_entity_by_id(&other, "post")
	source, _ := ecs.find_entity_by_id(&snapshot, "post")
	assert(ecs.add_component(&snapshot, registry, source, "PostProcessing",
		parse(`{"bloom":{"mode":"screen","intensity":0.7},"tonemap":{"mode":"agx"}}`)))
	assert(ecs.apply_value_snapshot(&other, &snapshot))
	value, _ := ecs.get(&other, target, ecs.PostProcessing)
	assert(value.bloom.mode == .screen && value.bloom.intensity == 0.7 && value.tonemap.mode == .agx)
	ecs.destroy(&other)
	assert(!ecs.add_component(&w, registry, e, "PostProcessing", parse(`{"bloom":{"intensity":-3}}`)))
	value, _ = ecs.get(&w, e, ecs.PostProcessing)
	assert(value.bloom.intensity == 0.12)
	report := validation.validate_scene("tools/post_processing_validation/fixtures/invalid.scene.json")
	defer validation.destroy_report(&report)
	assert(!validation.is_valid(&report) && len(report.diagnostics) > 0)
}

validate_mapping :: proc() {
	defaults := ecs.default_post_processing()
	base := r3d.ENVIRONMENT_BASE
	assert(bridge.post_processing_environment(base, defaults) == base, "Rune defaults match bundled r3d")
	base.background.energy = 3
	base.ambient.energy = 7
	value := defaults
	value.bloom.mode = .screen
	value.bloom.soft_threshold = 0.2
	value.tonemap.mode = .agx
	value.ssao.sample_count = 32
	value.ssil.gi_intensity = 2
	value.ssgi.denoise_steps = 2
	value.ssr.step_size = 0.25
	value.fog.mode = .exp
	value.fog.color = {10,20,30,255}
	value.dof.enabled = true
	value.auto_exposure.adaptation_to_dark = 2
	value.color.saturation = 0.4
	env := bridge.post_processing_environment(base, value)
	assert(env.background == base.background && env.ambient == base.ambient)
	assert(env.bloom.mode == .SCREEN && env.bloom.softThreshold == 0.2 && env.tonemap.mode == .AGX)
	assert(env.ssao.sampleCount == 32 && env.ssil.giIntensity == 2 && env.ssgi.denoiseSteps == 2)
	assert(env.ssr.stepSize == 0.25 && env.fog.mode == .EXP && env.fog.color == rl.Color{10,20,30,255})
	assert(env.dof.mode == .ENABLED && env.autoExposure.adaptationToDark == 2 && env.color.saturation == 0.4)
}

validate_runtime :: proc(registry: ^ecs.Component_Registry) {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320, 240, "Post processing validation")
	defer rl.CloseWindow()
	ctx, ok := bridge.init(".", 320, 240)
	assert(ok)
	defer bridge.shutdown(&ctx)
	w := ecs.init()
	defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	value := ecs.default_post_processing()
	value.bloom.mode = .additive
	value.tonemap.mode = .aces
	value.anti_aliasing = .smaa
	assert(ecs.add(&w, registry, e, value))
	r3d.GetEnvironment().tonemap.exposure = 1.7
	bridge.apply_post_processing(&ctx, &w, 0)
	assert(r3d.GetEnvironment().bloom.mode == .ADDITIVE && r3d.GetAntiAliasingMode() == .SMAA)
	// Exercise paths separately: r3d can prioritize one occlusion/GI algorithm
	// when several are enabled. Include a combined pass for interaction coverage.
	for pass in 0..<8 {
		value.ssao.enabled = pass == 0 || pass == 7
		value.ssil.enabled = pass == 1 || pass == 7
		value.ssgi.enabled = pass == 2 || pass == 7
		value.ssr.enabled = pass == 3 || pass == 7
		value.dof.enabled = pass == 4 || pass == 7
		value.auto_exposure.enabled = pass == 5 || pass == 7
		value.fog.mode = .exp2 if pass == 6 || pass == 7 else .disabled
		assert(ecs.set(&w, e, value))
		bridge.apply_post_processing(&ctx, &w, 0)
		for _ in 0..<3 {
			rl.BeginDrawing()
			r3d.Begin(rl.Camera3D{position = {3,3,3}, target = {0,0,0}, up = {0,1,0}, fovy = 45})
			r3d.DrawMesh(ctx.cube, r3d.GetDefaultMaterial(), {0,0,0}, 1)
			r3d.End()
			rl.EndDrawing()
		}
	}
	r3d.GetEnvironment().background.energy = 4
	assert(ecs.remove_component(&w, e, "PostProcessing"))
	bridge.apply_post_processing(&ctx, &w, 0)
	assert(r3d.GetEnvironment().bloom.mode == .DISABLED && r3d.GetEnvironment().tonemap.exposure == 1.7)
	assert(r3d.GetAntiAliasingMode() == .FXAA && r3d.GetEnvironment().background.energy == 4)
	r3d.GetEnvironment().tonemap.exposure = 2.5
	bridge.apply_post_processing(&ctx, &w, 0)
	assert(r3d.GetEnvironment().tonemap.exposure == 2.5, "profile-free games retain direct r3d control")
}

main :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	validate_data(&registry)
	validate_selection(&registry)
	validate_reload(&registry)
	validate_mapping()
	for arg in os.args[1:] {if arg == "--runtime" {validate_runtime(&registry)}}
	fmt.println("Post-processing validation passed")
}
