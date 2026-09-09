package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "rune:assets"
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
	defaults, ok := ecs.skybox_from_json(parse("{}"))
	assert(ok && defaults == ecs.default_skybox())
	assert(defaults.atmosphere.moon == "" && defaults.atmosphere.night_energy > 0)
	partial, valid := ecs.skybox_from_json(parse(`{"procedural":{"sun_size":3},"rotation":[0,45,0]}`))
	assert(valid && partial.procedural.sun_size == 3 && partial.procedural.sky_energy == 1 && partial.energy == 1)
	for bad in ([]string{
		`{"mode":"CUBEMAP"}`, `{"mode":1}`, `{"mode":"cubemap"}`, `{"texture":null}`,
		`{"texture":42}`, `{"layout":"nope"}`, `{"enabled":null}`, `{"energy":-1}`,
		`{"rotation":[1,2]}`, `{"resolution":0}`, `{"resolution":33}`, `{"resolution":4096}`,
		`{"resolution":32.5}`, `{"procedural":{"sun_size":0}}`, `{"unknown":1}`,
		`{"procedural":{"sun_direction":[0,0,0]}}`, `{"procedural":{"sun_curve":0}}`,
		`{"procedural":{"sky_top_color":[256,0,0,255]}}`, `{"procedural":{"typo":1}}`,
		`{"mode":"atmospheric"}`, `{"atmosphere":{"sun":null}}`, `{"atmosphere":{"mie":-1}}`,
		`{"atmosphere":{"rayleigh":11}}`, `{"atmosphere":{"mie_anisotropy":1}}`,
		`{"atmosphere":{"sun_size":0}}`, `{"atmosphere":{"ground_color":[1,2,3]}}`,
		`{"atmosphere":{"moon":null}}`, `{"atmosphere":{"moon_size":0}}`,
		`{"atmosphere":{"moon_size":21}}`, `{"atmosphere":{"night_energy":-1}}`,
		`{"atmosphere":{"night_color":[30,45,256,255]}}`,
	}) {
		_, accepted := ecs.skybox_from_json(parse(bad))
		assert(!accepted, bad)
	}
	w := ecs.init()
	defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	assert(ecs.add(&w, registry, e, partial))
	data, serialized := ecs.runtime_component_json(&w, e, "Skybox")
	assert(serialized)
	copy, copied := ecs.skybox_from_json(data)
	assert(copied && copy == partial)
	assert(ecs.set_runtime_field(&w, registry, e, "Skybox", "procedural.sun_size", json.Float(4)))
	value, _ := ecs.get(&w, e, ecs.Skybox)
	assert(value.procedural.sun_size == 4)
	assert(!ecs.set_runtime_field(&w, registry, e, "Skybox", "energy", json.Integer(-1)))
	unchanged, _ := ecs.get(&w, e, ecs.Skybox)
	assert(unchanged == value)
	value.energy = math.nan_f32()
	assert(!ecs.set(&w, e, value) && !ecs.add(&w, registry, e, value))
	value = defaults
	value.mode = .cubemap
	value.texture = "assets/sky.hdr"
	assert(ecs.set(&w, e, value))
	data, serialized = ecs.runtime_component_json(&w, e, "Skybox")
	copy, copied = ecs.skybox_from_json(data)
	assert(serialized && copied && copy == value)
	value.mode = .atmospheric
	value.atmosphere.sun = "sun"
	value.atmosphere.moon = "moon"
	assert(ecs.set(&w,e,value))
	data, serialized = ecs.runtime_component_json(&w,e,"Skybox")
	copy, copied = ecs.skybox_from_json(data)
	assert(serialized && copied && copy == value)
	assert(ecs.set_runtime_field(&w,registry,e,"Skybox","atmosphere.mie",json.Float(2)))
	assert(ecs.set_runtime_field(&w,registry,e,"Skybox","atmosphere.moon",json.String("")))
	assert(ecs.set_runtime_field(&w,registry,e,"Skybox","atmosphere.night_energy",json.Float(0)))
	value, _ = ecs.get(&w,e,ecs.Skybox)
	assert(value.atmosphere.moon == "" && value.atmosphere.night_energy == 0)
	value.atmosphere.night_energy = math.inf_f32(1)
	assert(!ecs.set(&w,e,value))
	assert(!ecs.set_runtime_field(&w,registry,e,"Skybox","atmosphere.sun",json.String("")))
	assert(ecs.remove_component(&w, e, "Skybox"))
	_, remains := ecs.get(&w, e, ecs.Skybox)
	assert(!remains)
	assert(ecs.add(&w, registry, e, defaults))
	assert(ecs.destroy_entity(&w, e) && len(w.skyboxes) == 0)
}

validate_selection :: proc(registry: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	a, b, camera, parent := ecs.create_entity(&w), ecs.create_entity(&w), ecs.create_entity(&w), ecs.create_entity(&w)
	for e, i in ([]ecs.Entity{a,b,camera}) {
		value := ecs.default_skybox()
		value.energy = f32(i+1)
		assert(ecs.add(&w, registry, e, value))
	}
	assert(ecs.add_component(&w, registry, camera, "Camera3D", parse("{}")))
	value, found := ecs.active_skybox(&w, 0)
	assert(found && value.energy == 1)
	value, found = ecs.active_skybox(&w, camera)
	assert(found && value.energy == 3)
	assert(ecs.set_enabled(&w, camera, false))
	assert(ecs.set_parent(&w, a, parent) && ecs.set_enabled(&w, parent, false))
	value, found = ecs.active_skybox(&w, camera)
	assert(found && value.energy == 2)
	value.enabled = false
	assert(ecs.set(&w, b, value))
	_, found = ecs.active_skybox(&w, 0)
	assert(!found)
}

validate_reload :: proc(registry: ^ecs.Component_Registry) {
	path :: "examples/skybox_3d/scenes/main.scene.json"
	w, ok := scene.load(path, registry)
	assert(ok, scene.last_load_error())
	defer ecs.destroy(&w)
	_, _, camera_found := ecs.active_camera_3d(&w)
	assert(camera_found)
	snapshot, loaded := scene.load(path, registry)
	assert(loaded)
	target, _ := ecs.find_entity_by_id(&w, "sky")
	source, _ := ecs.find_entity_by_id(&snapshot, "sky")
	assert(ecs.add_component(&snapshot, registry, source, "Skybox", parse(`{"mode":"cubemap","texture":"sky.png"}`)))
	assert(ecs.apply_value_snapshot(&w, &snapshot))
	ecs.destroy(&snapshot)
	value, found := ecs.get(&w, target, ecs.Skybox)
	assert(found && value.mode == .cubemap && value.texture == "sky.png")
	// A second snapshot must retain the sun reference after its arena is adopted.
	next, next_ok := scene.load(path,registry)
	assert(next_ok)
	assert(ecs.apply_value_snapshot(&w,&next))
	ecs.destroy(&next)
	value, found = ecs.get(&w,target,ecs.Skybox)
	assert(found && value.mode == .atmospheric && value.atmosphere.sun == "sun" && value.atmosphere.moon == "moon")
	report := validation.validate_project("examples/skybox_3d/project.json")
	defer validation.destroy_report(&report)
	assert(validation.is_valid(&report))
	bad := validation.validate_scene("tools/skybox_validation/fixtures/invalid.scene.json")
	defer validation.destroy_report(&bad)
	assert(!validation.is_valid(&bad))
}

validate_sun :: proc(registry: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	assert(ecs.set_entity_metadata(&w,e,"sun","","",1))
	assert(ecs.add_component(&w,registry,e,"DirectionalLight",parse(`{"direction":[0,-2,0],"color":[255,128,0,255],"intensity":2}`)))
	sun, ok := bridge.atmospheric_sun(&w,"sun")
	assert(ok && sun.direction == ([3]f32{0,1,0}))
	assert(sun.radiance[0] == 40 && sun.radiance[1] > 20 && sun.radiance[2] == 0)
	parent := ecs.create_entity(&w)
	assert(ecs.set_parent(&w,e,parent) && ecs.set_enabled(&w,parent,false))
	sun, ok = bridge.atmospheric_sun(&w,"sun")
	assert(ok && sun.radiance == ([3]f32{}))
	assert(ecs.set_enabled(&w,parent,true))
	light, _ := ecs.get_directional_light(&w,e)
	light.direction = {0,0,0}
	assert(ecs.set_directional_light(&w,e,light))
	_, ok = bridge.atmospheric_sun(&w,"sun")
	assert(!ok)
	light.direction = {0,math.inf_f32(1),0}
	assert(ecs.set_directional_light(&w,e,light))
	_, ok = bridge.atmospheric_sun(&w,"sun")
	assert(!ok)
	_, ok = bridge.atmospheric_sun(&w,"absent")
	assert(!ok)
}

validate_runtime :: proc(registry: ^ecs.Component_Registry) {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,180,"Skybox validation")
	defer rl.CloseWindow()
	ctx, ok := bridge.init("build",320,180)
	assert(ok)
	defer bridge.shutdown(&ctx)
	manager := assets.init("build")
	defer assets.shutdown(&manager)
	w := ecs.init()
	defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	value := ecs.default_skybox()
	value.resolution = 32
	assert(ecs.add(&w, registry, e, value))
	bridge.apply_skybox(&ctx,&w,&manager,0)
	first := ctx.skybox.cubemap.texture
	assert(first != 0 && r3d.GetEnvironment().background.sky.texture == first)
	camera := ecs.create_entity(&w)
	assert(ecs.add_component(&w, registry, camera, "Transform", parse(`{"position":[3,3,3]}`)))
	assert(ecs.add_component(&w, registry, camera, "Camera3D", parse(`{"active":true}`)))
	for _ in 0..<3 {
		rl.BeginDrawing()
		assert(bridge.draw_scene(&ctx,&w,&manager))
		rl.EndDrawing()
	}
	value.rotation = {0,90,0}
	value.energy = 2
	assert(ecs.set(&w,e,value))
	bridge.apply_skybox(&ctx,&w,&manager,0)
	assert(ctx.skybox.cubemap.texture == first && r3d.GetEnvironment().background.energy == 2)
	post := ecs.default_post_processing()
	assert(ecs.add(&w, registry, e, post))
	bridge.apply_post_processing(&ctx,&w,0)
	assert(r3d.GetEnvironment().background.sky.texture == first)
	assert(ecs.remove_component(&w,e,"PostProcessing"))
	bridge.apply_post_processing(&ctx,&w,0)
	assert(r3d.GetEnvironment().background.sky.texture == first)
	value.procedural.sky_top_color = {220,30,20,255}
	assert(ecs.set(&w,e,value))
	bridge.apply_skybox(&ctx,&w,&manager,0)
	assert(ctx.skybox.cubemap.texture != 0 && ctx.skybox.requested.procedural == value.procedural)
	image := rl.GenImageColor(128,64,rl.BLUE)
	defer rl.UnloadImage(image)
	assert(rl.ExportImage(image,"build/skybox-validation.png"))
	value.mode = .cubemap
	value.layout = .panorama
	value.texture = "skybox-validation.png"
	assert(ecs.set(&w,e,value))
	bridge.apply_skybox(&ctx,&w,&manager,0)
	first = ctx.skybox.cubemap.texture
	assert(first != 0)
	assert(os.write_entire_file("build/skybox-validation.png","broken") == nil)
	assets.refresh_skyboxes(&manager)
	assert(assets.skybox_revision(&manager,value.texture) > ctx.skybox.revision)
	bridge.apply_skybox(&ctx,&w,&manager,0)
	assert(ctx.skybox.cubemap.texture == first, "broken reload keeps last good cubemap")
	assert(rl.ExportImage(image,"build/skybox-validation.png"))
	assets.refresh_skyboxes(&manager)
	bridge.apply_skybox(&ctx,&w,&manager,0)
	assert(ctx.skybox.cubemap.texture != 0 && ctx.skybox.cubemap.texture != first)
	assert(len(manager.diagnostics.reported) == 0, "successful reload clears asset diagnostic")
	value.texture = "skybox-validation-missing.png"
	os.remove("build/skybox-validation-missing.png")
	assert(ecs.set(&w,e,value))
	bridge.apply_skybox(&ctx,&w,&manager,0)
	assert(ctx.skybox.cubemap.texture == 0 && ctx.skybox.attempted)
	assert(rl.ExportImage(image,"build/skybox-validation-missing.png"))
	assets.refresh_skyboxes(&manager)
	bridge.apply_skybox(&ctx,&w,&manager,0)
	assert(ctx.skybox.cubemap.texture != 0, "missing file recovers after creation")
	value.enabled = false
	assert(ecs.set(&w,e,value))
	bridge.apply_skybox(&ctx,&w,&manager,0)
	assert(ctx.skybox.cubemap.texture == 0 && r3d.GetEnvironment().background.sky.texture == 0)
	value.enabled = true
	assert(ecs.set(&w,e,value))
	bridge.apply_skybox(&ctx,&w,&manager,0)
	assert(ctx.skybox.cubemap.texture != 0)
	assert(ecs.set_enabled(&w,camera,false))
	assert(!bridge.draw_scene(&ctx,&w,&manager) && ctx.skybox.cubemap.texture == 0)
	assert(ecs.set_enabled(&w,camera,true))
	validate_atmosphere_runtime(&ctx,&w,&manager,registry,e,camera)
	os.remove("build/skybox-validation.png")
	os.remove("build/skybox-validation-missing.png")
	fmt.println("PASS skybox runtime lifecycle and recovery")
}

validate_atmosphere_runtime :: proc(ctx: ^bridge.Context, w: ^ecs.World, manager: ^assets.Asset_Manager,
	registry: ^ecs.Component_Registry, sky, camera: ecs.Entity) {
	value := ecs.default_skybox()
	value.mode = .atmospheric
	value.resolution = 32
	value.atmosphere.sun = "sun"
	value.rotation = {20,90,10}
	assert(ecs.set(w,sky,value))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.cubemap.texture == 0, "missing light falls back, not a stale sun")
	sun := ecs.create_entity(w)
	assert(ecs.set_entity_metadata(w,sun,"sun","","",1))
	assert(ecs.add_component(w,registry,sun,"DirectionalLight",parse(`{"direction":[0,-1,0]}`)))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.cubemap.texture != 0 && ctx.skybox.atmosphere_shader != nil)
	assert(r3d.GetEnvironment().background.rotation == quaternion128(1), "sun stays world aligned")
	first, shader, revision := ctx.skybox.cubemap.texture, ctx.skybox.atmosphere_shader, ctx.skybox.revision
	for _ in 0..<3 {
		rl.BeginDrawing()
		assert(bridge.draw_scene(ctx,w,manager))
		rl.EndDrawing()
	}
	assert(ctx.skybox.revision == revision, "static skies are cached")
	light, _ := ecs.get_directional_light(w,sun)
	light.direction = {0,-0.02,1}
	light.color = {255,100,40,255}
	light.intensity = 0.75
	assert(ecs.set_directional_light(w,sun,light))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.revision == revision+1 && ctx.skybox.cubemap.texture == first && ctx.skybox.atmosphere_shader == shader,
		"sun edits update the cubemap in place")
	assert(ctx.skybox.sun.radiance[0] == 15 && ctx.skybox.sun.direction[2] < 0)
	value.atmosphere.mie = 3
	assert(ecs.set(w,sky,value))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.revision == revision+2 && ctx.skybox.cubemap.texture == first)
	assert(ecs.set_enabled(w,sun,false))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.sun.radiance == ([3]f32{}))
	value.atmosphere.moon = "moon"
	assert(ecs.set(w,sky,value))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.cubemap.texture == first && ctx.skybox.moon.radiance == ([3]f32{}), "missing optional moon preserves sky")
	moon := ecs.create_entity(w)
	assert(ecs.set_entity_metadata(w,moon,"moon","","",1))
	assert(ecs.add_component(w,registry,moon,"DirectionalLight",parse(`{"direction":[0,-1,0],"intensity":0.03}`)))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.moon.radiance[0] > 0 && ctx.skybox.cubemap.texture == first)
	assert(len(manager.diagnostics.reported) == 0, "moon creation clears diagnostic")
	validate_moon_disk(ctx,w,manager,registry,sky,camera,moon)
	// Restore the settings changed by the pixel checks.
	assert(ecs.set(w,sky,value))
	bridge.apply_skybox(ctx,w,manager,camera)
	first = ctx.skybox.cubemap.texture
	moon_revision := ctx.skybox.revision
	moon_light, _ := ecs.get_directional_light(w,moon)
	moon_light.direction = {1,-1,0}
	assert(ecs.set_directional_light(w,moon,moon_light))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.revision == moon_revision+1 && ctx.skybox.cubemap.texture == first)
	assert(ecs.set_enabled(w,moon,false))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.moon.radiance == ([3]f32{}))
	assert(ecs.destroy_entity(w,moon))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.cubemap.texture == first)
	value.atmosphere.moon = ""
	value.atmosphere.night_energy = 0
	assert(ecs.set(w,sky,value))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(len(manager.diagnostics.reported) == 0 && ctx.skybox.cubemap.texture == first)
	assert(ecs.destroy_entity(w,sun))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.cubemap.texture == 0 && ctx.skybox.atmosphere_shader == nil)
	assert(ctx.skybox.moon_shader == nil)
	value.mode = .procedural
	assert(ecs.set(w,sky,value))
	bridge.apply_skybox(ctx,w,manager,camera)
	assert(ctx.skybox.cubemap.texture != 0 && ctx.skybox.atmosphere_shader == nil)
}

moon_frame :: proc(ctx: ^bridge.Context, w: ^ecs.World, manager: ^assets.Asset_Manager) -> rl.Image {
	rl.BeginDrawing()
	assert(bridge.draw_scene(ctx,w,manager))
	frame := rl.LoadImageFromScreen()
	rl.EndDrawing()
	return frame
}

validate_moon_disk :: proc(ctx: ^bridge.Context, w: ^ecs.World, manager: ^assets.Asset_Manager,
	registry: ^ecs.Component_Registry, sky, camera, moon: ecs.Entity) {
	assert(ctx.skybox.moon_shader != nil)
	value, _ := ecs.get_skybox(w,sky)
	value.atmosphere.rayleigh = 0
	value.atmosphere.mie = 0
	value.atmosphere.night_energy = 0
	value.atmosphere.moon_size = 6
	value.atmosphere.ground_color = {0,0,0,255}
	value.resolution = 256
	assert(ecs.set(w,sky,value))
	assert(ecs.set_runtime_field(w,registry,camera,"Transform","position",parse(`[0,0,0]`)))
	assert(ecs.set_runtime_field(w,registry,camera,"Camera3D","target",parse(`[0,0.2,-1]`)))
	assert(ecs.set_runtime_field(w,registry,moon,"DirectionalLight","direction",parse(`[0,-0.2,1]`)))
	first := moon_frame(ctx,w,manager)
	defer rl.UnloadImage(first)
	center := rl.GetImageColor(first,160,90)
	assert(center.r > 40, "moon disk renders at the camera's center")
	value.resolution = 16
	assert(ecs.set(w,sky,value))
	low := moon_frame(ctx,w,manager)
	defer rl.UnloadImage(low)
	for y: i32 = 60; y < 120; y += 1 {
		for x: i32 = 130; x < 190; x += 1 {
			a, b := rl.GetImageColor(first,x,y), rl.GetImageColor(low,x,y)
			assert(abs(i32(a.r)-i32(b.r)) <= 1, "moon edge is independent of sky cubemap resolution")
		}
	}
	blocker := ecs.create_entity(w)
	assert(ecs.add_component(w,registry,blocker,"Transform",parse(`{"position":[0,0.4,-2],"scale":[5,5,0.1]}`)))
	assert(ecs.add_component(w,registry,blocker,"MeshRenderer",parse(`{"primitive":"cube","color":[0,0,0,255]}`)))
	blocked := moon_frame(ctx,w,manager)
	defer rl.UnloadImage(blocked)
	assert(rl.GetImageColor(blocked,160,90).r < 5, "foreground geometry occludes the moon")
	assert(ecs.destroy_entity(w,blocker))
}

main :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	validate_data(&registry)
	validate_selection(&registry)
	validate_reload(&registry)
	validate_sun(&registry)
	assert(bridge.procedural_sky_parameters(ecs.default_skybox().procedural) == r3d.PROCEDURAL_SKY_BASE)
	for arg in os.args[1:] {if arg == "--runtime" {validate_runtime(&registry)}}
	fmt.println("PASS skybox validation")
}
