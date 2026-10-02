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
	height, height_ok := ecs.post_processing_from_json(parse(`{"height_fog":{"enabled":true,"base_height":-35,"density":0.008,"falloff":0}}`))
	assert(height_ok && height.height_fog.enabled && height.height_fog.base_height == -35 && height.height_fog.falloff == 0)
	height_json, height_serialized := ecs.post_processing_json(height)
	height_copy, height_roundtrip := ecs.post_processing_from_json(height_json)
	assert(height_serialized && height_roundtrip && height_copy == height)
	upper,upper_ok:=ecs.post_processing_from_json(parse(`{"upper_height_fog":{"enabled":true,"base_height":180,"density":0.012,"falloff":0.025}}`))
	assert(upper_ok && upper.upper_height_fog.enabled && !upper.height_fog.enabled)
	assert(upper.upper_height_fog.base_height==180 && upper.upper_height_fog.sky_distance==1000)
	upper_json,upper_serialized:=ecs.post_processing_json(upper)
	upper_copy,upper_roundtrip:=ecs.post_processing_from_json(upper_json)
	assert(upper_serialized && upper_roundtrip && upper_copy==upper)
	grain,grain_ok:=ecs.post_processing_from_json(parse(`{"film_grain":{"enabled":true,"intensity":0.025}}`))
	assert(grain_ok && grain.film_grain.enabled && grain.film_grain.size==1 && grain.film_grain.speed==24)
	grain_json,grain_serialized:=ecs.post_processing_json(grain)
	grain_copy,grain_roundtrip:=ecs.post_processing_from_json(grain_json)
	assert(grain_serialized && grain_roundtrip && grain_copy==grain)
	for bad in ([]string{
		`{"bloom":{"mode":"ADDITIVE"}}`, `{"bloom":{"mode":2}}`, `{"bloom":{"intensity":-1}}`,
		`{"bloom":{"levels":1.01}}`, `{"bloom":{"typo":1}}`, `{"ssao":{"sample_count":0}}`,
		`{"ssao":{"sample_count":1.5}}`, `{"ssao":{"sample_count":2147483648}}`,
		`{"ssao":{"radius":0}}`, `{"ssr":{"max_ray_steps":257}}`, `{"dof":{"focus_scale":0}}`,
		`{"fog":{"start":5,"end":4}}`, `{"fog":{"color":[256,0,0,255]}}`,
		`{"fog":{"color":[0.5,0,0,255]}}`, `{"auto_exposure":{"min_ev":3,"max_ev":2}}`,
		`{"anti_aliasing":"msaa"}`, `{"enabled":null}`, `{"bloom":null}`,
		`{"height_fog":{"density":-1}}`, `{"height_fog":{"falloff":-1}}`,
		`{"height_fog":{"base_height":null}}`, `{"height_fog":{"color":[0,0,0]}}`,
		`{"height_fog":{"sky_distance":0}}`,
		`{"upper_height_fog":{"density":-1}}`, `{"upper_height_fog":{"falloff":-1}}`,
		`{"upper_height_fog":{"base_height":null}}`, `{"upper_height_fog":{"color":[0,0,0]}}`,
		`{"upper_height_fog":{"sky_distance":0}}`, `{"upper_height_fog":{"typo":1}}`,
		`{"film_grain":null}`, `{"film_grain":{"enabled":1}}`,
		`{"film_grain":{"intensity":-0.01}}`, `{"film_grain":{"intensity":1.01}}`,
		`{"film_grain":{"size":0}}`, `{"film_grain":{"size":8.01}}`,
		`{"film_grain":{"speed":-1}}`, `{"film_grain":{"speed":60.01}}`, `{"film_grain":{"typo":1}}`,
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
	assert(ecs.set_runtime_field(&w, registry, e, "PostProcessing", "height_fog.base_height", json.Integer(-40)))
	current, _ = ecs.get(&w, e, ecs.PostProcessing)
	assert(current.height_fog.base_height == -40)
	assert(!ecs.set_runtime_field(&w, registry, e, "PostProcessing", "height_fog.density", json.Integer(-1)))
	unchanged, _ = ecs.get(&w, e, ecs.PostProcessing)
	assert(unchanged == current)
	current.height_fog.base_height = math.nan_f32()
	assert(!ecs.set(&w, e, current))
	assert(ecs.set_runtime_field(&w,registry,e,"PostProcessing","upper_height_fog.base_height",json.Integer(180)))
	current,_=ecs.get(&w,e,ecs.PostProcessing)
	assert(current.upper_height_fog.base_height==180)
	assert(!ecs.set_runtime_field(&w,registry,e,"PostProcessing","upper_height_fog.falloff",json.Integer(-1)))
	unchanged,_=ecs.get(&w,e,ecs.PostProcessing); assert(unchanged==current)
	current.upper_height_fog.density=math.inf_f32(1)
	assert(!ecs.set(&w,e,current))
	assert(ecs.set_runtime_field(&w,registry,e,"PostProcessing","film_grain.intensity",json.Float(0.03)))
	current,_=ecs.get(&w,e,ecs.PostProcessing)
	assert(current.film_grain.intensity==0.03)
	assert(!ecs.set_runtime_field(&w,registry,e,"PostProcessing","film_grain.size",json.Integer(0)))
	unchanged,_=ecs.get(&w,e,ecs.PostProcessing); assert(unchanged==current)
	current.film_grain.speed=math.inf_f32(1); assert(!ecs.set(&w,e,current))
	current = partial
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
		parse(`{"bloom":{"mode":"screen","intensity":0.7},"tonemap":{"mode":"agx"},"upper_height_fog":{"enabled":true,"base_height":210,"density":0.012},"film_grain":{"enabled":true,"intensity":0.025}}`)))
	assert(ecs.apply_value_snapshot(&other, &snapshot))
	value, _ := ecs.get(&other, target, ecs.PostProcessing)
	assert(value.bloom.mode == .screen && value.bloom.intensity == 0.7 && value.tonemap.mode == .agx)
	assert(value.upper_height_fog.enabled && value.upper_height_fog.base_height==210 && value.upper_height_fog.density==0.012)
	assert(value.film_grain.enabled && value.film_grain.intensity==0.025 && value.film_grain.speed==24)
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
	// Render through the bridge to exercise the actual height-fog shader and
	// stage cleanup. A black sky should fade to white below the horizon.
	camera := ecs.create_entity(&w)
	assert(ecs.add_component(&w, registry, camera, "Transform", parse(`{"position":[0,2,0]}`)))
	assert(ecs.add_component(&w, registry, camera, "Camera3D", parse(`{"target":[0,2,-1],"fovy":60,"active":true}`)))
	value = ecs.default_post_processing()
	value.anti_aliasing = .disabled
	value.height_fog.enabled = true
	value.height_fog.density = 0.001
	value.height_fog.falloff = 0.2
	assert(ecs.add(&w, registry, e, value))
	for pass in 0..<8 {
		if pass == 1 {value.height_fog.enabled = false; assert(ecs.set(&w, e, value))}
		if pass == 2 {value.height_fog.enabled = true; value.height_fog.falloff = 0; assert(ecs.set(&w, e, value))}
		if pass == 3 {assert(ecs.remove_component(&w, e, "PostProcessing"))}
		if pass>=4 {
			value=ecs.default_post_processing(); value.anti_aliasing=.disabled
			value.upper_height_fog.enabled=true; value.upper_height_fog.base_height=2
			value.upper_height_fog.density=0.001; value.upper_height_fog.falloff=0.2
			if pass==5 {value.height_fog.enabled=true; value.height_fog.density=0.001; value.height_fog.falloff=0.2}
			if pass==6 {value.upper_height_fog.falloff=0}
			if pass==7 {value.upper_height_fog.density=0}
			assert(ecs.add(&w,registry,e,value))
		}
		for _ in 0..<3 {
			rl.BeginDrawing()
			assert(bridge.draw_scene_ex(&ctx, &w, nil, {background_color = rl.BLACK}))
			rl.EndDrawing()
		}
		assert(ctx.height_fog_shader != nil, "height fog shader must compile on the GPU")
		image := rl.LoadImageFromScreen()
		upper := rl.GetImageColor(image, 160, 20)
		middle := rl.GetImageColor(image, 160, 120)
		lower := rl.GetImageColor(image, 160, 220)
		rl.UnloadImage(image)
		if pass == 0 {assert(upper.r < 80 && lower.r > 240 && middle.r > upper.r, "height fog must thicken downward")}
		if pass == 1 || pass == 3 {assert(upper.r == 0 && middle.r == 0 && lower.r == 0, "disabled or removed fog must leave no shader chain")}
		if pass == 2 {assert(upper.r > 150 && middle.r > 150 && lower.r > 150, "zero falloff must give uniform distance fog")}
		if pass==4 {assert(upper.r>240 && lower.r<80 && middle.r>lower.r,"upper height fog must thicken upward")}
		if pass==5 {assert(upper.r>240 && lower.r>240 && middle.r>150,"both height fog layers must compose")}
		if pass==6 {assert(upper.r>150 && middle.r>150 && lower.r>150,"upper zero falloff must give uniform fog")}
		if pass==7 {assert(upper.r==0 && middle.r==0 && lower.r==0,"zero-density upper fog must leave no shader chain")}
	}
	validate_grain_runtime(&ctx,&w,registry,e)
}

grain_frame :: proc(ctx:^bridge.Context,w:^ecs.World) -> rl.Image {
	for _ in 0..<3 {
		rl.BeginDrawing()
		assert(bridge.draw_scene_ex(ctx,w,nil,{background_color={96,96,96,255}}))
		rl.EndDrawing()
	}
	return rl.LoadImageFromScreen()
}

assert_flat_frame :: proc(image:rl.Image) {
	low,high:=255,0
	for y in 40..<72 {for x in 40..<72 {
		p:=rl.GetImageColor(image,i32(x),i32(y))
		low=min(low,int(p.r)); high=max(high,int(p.r))
	}}
	// r3d's output pass already dithers before sRGB conversion; that small
	// static variation is independent of film grain and must remain intact.
	assert(high-low<=3,"disabled/removed grain must leave only native output dithering")
}

validate_grain_runtime :: proc(ctx:^bridge.Context,w:^ecs.World,registry:^ecs.Component_Registry,e:ecs.Entity) {
	value:=ecs.default_post_processing()
	assert(ecs.set(w,e,value))
	baseline:=grain_frame(ctx,w); defer rl.UnloadImage(baseline)
	assert_flat_frame(baseline)
	value.film_grain={enabled=true,intensity=0.08,size=2,speed=0}
	assert(ecs.set(w,e,value))
	grain:=grain_frame(ctx,w); defer rl.UnloadImage(grain)
	assert(ctx.film_grain_shader!=nil,"film grain shader must compile on the GPU")
	signed_delta,absolute_delta:int
	for y in 40..<72 {for x in 40..<72 {
		p:=rl.GetImageColor(grain,i32(x),i32(y))
		base:=rl.GetImageColor(baseline,i32(x),i32(y))
		delta:=int(p.r)-int(base.r)
		signed_delta+=delta; absolute_delta+=abs(delta)
		assert(p.r==p.g && p.g==p.b,"monochrome grain must not tint neutral colors")
		if x%2==0 {
			next:=rl.GetImageColor(grain,i32(x+1),i32(y)); next_base:=rl.GetImageColor(baseline,i32(x+1),i32(y))
			assert(abs(delta-(int(next.r)-int(next_base.r)))<=1,"two-pixel grain must remain sharp after AA")
		}
	}}
	assert(absolute_delta>1024 && abs(signed_delta)<1024,"grain must vary pixels without a brightness shift")
	still:=grain_frame(ctx,w); defer rl.UnloadImage(still)
	for y in 40..<72 {for x in 40..<72 {assert(rl.GetImageColor(still,i32(x),i32(y))==rl.GetImageColor(grain,i32(x),i32(y)),"speed zero must freeze grain")}}
	value.film_grain.speed=60; assert(ecs.set(w,e,value))
	animated:=grain_frame(ctx,w); defer rl.UnloadImage(animated)
	rl.WaitTime(0.04)
	later:=grain_frame(ctx,w); defer rl.UnloadImage(later)
	changed:int
	for y in 40..<72 {for x in 40..<72 {if rl.GetImageColor(animated,i32(x),i32(y))!=rl.GetImageColor(later,i32(x),i32(y)) {changed+=1}}}
	assert(changed>256,"grain must animate across frames")
	value.film_grain.intensity=0; assert(ecs.set(w,e,value))
	zero:=grain_frame(ctx,w); defer rl.UnloadImage(zero); assert_flat_frame(zero)
	value.film_grain.intensity=0.08; value.film_grain.enabled=false; assert(ecs.set(w,e,value))
	off:=grain_frame(ctx,w); defer rl.UnloadImage(off); assert_flat_frame(off)
	value.film_grain.enabled=true; value.enabled=false; assert(ecs.set(w,e,value))
	disabled:=grain_frame(ctx,w); defer rl.UnloadImage(disabled); assert_flat_frame(disabled)
	assert(ecs.remove_component(w,e,"PostProcessing"))
	removed:=grain_frame(ctx,w); defer rl.UnloadImage(removed); assert_flat_frame(removed)
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
