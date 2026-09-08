package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "rune:assets"
import "rune:audio"
import "rune:ecs"
import "rune:render"
import "rune:scene"
import "rune:validation"
import rl "vendor:raylib"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}
add :: proc(w: ^ecs.World, r: ^ecs.Component_Registry, e: ecs.Entity, name, text: string) {
	assert(ecs.add_component(w, r, e, name, parse(text)), name)
}
entity :: proc(w: ^ecs.World, id: string) -> ecs.Entity {
	result, ok := ecs.find_entity_by_id(w, id)
	assert(ok, id)
	return result
}

validate_activation :: proc(r: ^ecs.Component_Registry) {
	w, ok := scene.load("tools/component_features_validation/fixtures/main.scene.json", r)
	assert(ok, scene.last_load_error())
	defer ecs.destroy(&w)
	assign_prefab_ids(&w)
	parent, child := entity(&w, "parent"), entity(&w, "child")
	assert(!ecs.is_enabled(&w, entity(&w, "inherited")), "prefab default")
	assert(ecs.is_enabled(&w, entity(&w, "overridden")), "explicit true overrides prefab")
	assert(ecs.is_enabled(&w, entity(&w, "default")), "absent enabled defaults true")
	assert(ecs.is_locally_enabled(&w, child) && !ecs.is_enabled(&w, child))
	assert(len(ecs.query(&w, ecs.ShapeRenderer2D)) == 0)
	assert(len(ecs.query(&w, ecs.ShapeRenderer2D, include_disabled = true)) == 3)
	assert(len(ecs.query2(&w, ecs.ShapeRenderer2D, ecs.Lifetime)) == 0)
	assert(len(ecs.query2(&w, ecs.ShapeRenderer2D, ecs.Lifetime, include_disabled = true)) == 1)
	_, exists := ecs.get(&w, child, ecs.ShapeRenderer2D)
	assert(exists, "disabled data remains accessible")
	ecs.update_lifetimes(&w, 1)
	assert(w.lifetime_elapsed[child] == 0)
	assert(ecs.set_enabled(&w, parent, true))
	assert(ecs.is_enabled(&w, child))
	ecs.update_lifetimes(&w, 0.5)
	assert(ecs.set_enabled(&w, child, false))
	ecs.set_enabled(&w, parent, false)
	ecs.set_enabled(&w, parent, true)
	assert(!ecs.is_enabled(&w, child), "parent toggle preserves child setting")
	ecs.set_enabled(&w, child, true)
	assert(ecs.set_parent(&w, child, entity(&w, "inherited")))
	assert(!ecs.is_enabled(&w, child), "reparenting inherits activation")
	assert(ecs.set_parent(&w, child, parent))
	assert(ecs.is_enabled(&w, child))
	snapshot, loaded := scene.load("tools/component_features_validation/fixtures/main.scene.json", r)
	assert(loaded)
	defer ecs.destroy(&snapshot)
	assign_prefab_ids(&snapshot)
	assert(ecs.apply_value_snapshot(&w, &snapshot))
	assert(!ecs.is_enabled(&w, child) && w.lifetime_elapsed[child] == 0.5, "reload restores activation without resetting unchanged lifetime")
	report := validation.validate_scene("tools/component_features_validation/fixtures/invalid.scene.json")
	defer validation.destroy_report(&report)
	assert(!validation.is_valid(&report) && len(report.diagnostics) == 3)
}

validate_components :: proc(r: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	shape := ecs.default_shape_renderer_2d()
	assert(ecs.add(&w, r, e, shape))
	assert(ecs.add(&w, r, e, ecs.Lifetime{1}))
	data, ok := ecs.runtime_component_json(&w, e, "ShapeRenderer2D")
	assert(ok && ecs.add_component(&w, r, e, "ShapeRenderer2D", data), "serialization roundtrip")
	assert(ecs.set_runtime_field(&w, r, e, "ShapeRenderer2D", "shape", json.String("circle")))
	actual, _ := ecs.get(&w, e, ecs.ShapeRenderer2D)
	assert(actual.shape == .circle && actual.color == shape.color)
	assert(!ecs.set_runtime_field(&w, r, e, "ShapeRenderer2D", "radius", json.Integer(-1)))
	for bad in ([]string{`{"shape":"triangle"}`, `{"size":[0,2]}`, `{"color":[256,0,0,255]}`, `{"unknown":1}`, `{"filled":1}`, `{"line_width":0}`}) {
		assert(!ecs.add_component(&w, r, e, "ShapeRenderer2D", parse(bad)), bad)
	}
	for bad in ([]string{`{}`, `{"seconds":-1}`, `{"seconds":"1"}`, `{"seconds":1,"elapsed":0}`}) {
		assert(!ecs.add_component(&w, r, e, "Lifetime", parse(bad)), bad)
	}
	shape.radius = math.inf_f32(1)
	assert(!ecs.set(&w, e, shape))
	assert(!ecs.set(&w, e, ecs.Lifetime{math.nan_f32()}))
	ecs.update_lifetimes(&w, 0.75)
	ecs.set_enabled(&w, e, false)
	ecs.update_lifetimes(&w, 100)
	ecs.set_enabled(&w, e, true)
	ecs.update_lifetimes(&w, 0)
	assert(ecs.is_alive(&w, e))
	assert(ecs.set(&w, e, ecs.Lifetime{1}))
	ecs.update_lifetimes(&w, 0.75)
	assert(ecs.is_alive(&w, e), "setting lifetime restarts countdown")
	child := ecs.create_entity(&w)
	ecs.set_parent(&w, child, e)
	assert(ecs.add(&w, r, child, ecs.Lifetime{0.25}))
	ecs.update_lifetimes(&w, 0.25)
	assert(!ecs.is_alive(&w, e) && !ecs.is_alive(&w, child), "parent and child can expire together safely")
	assert(len(w.lifetime_elapsed) == 0)
	assert(!ecs.set_enabled(&w, e, true))
}

validate_physics :: proc(r: ^ecs.Component_Registry, dimension: int) {
	w := ecs.init()
	defer ecs.destroy(&w)
	parent, body := ecs.create_entity(&w), ecs.create_entity(&w)
	ecs.set_parent(&w, body, parent)
	add(&w, r, body, "Transform", `{"position":[10,0,0]}`)
	if dimension == 2 {
		add(&w, r, body, "BoxCollider2D", `{"size":[2,2]}`)
		add(&w, r, body, "RigidBody2D", `{"velocity":[2,0],"gravity_scale":0}`)
	} else {
		add(&w, r, body, "BoxCollider", `{"size":[2,2,2]}`)
		add(&w, r, body, "RigidBody3D", `{"velocity":[2,0,0],"gravity_scale":0}`)
	}
	for _ in 0..<3 {
		assert(ray(&w, dimension), "enabled body participates in immediate queries")
		if dimension == 2 {ecs.physics_2d_update(&w, 1.0/60)} else {ecs.physics_3d_update(&w, 1.0/60)}
		before, _ := ecs.get_transform(&w, body)
		ecs.set_enabled(&w, parent, false)
		assert(!ray(&w, dimension), "disabled subtree removed before next physics step")
		if dimension == 2 {ecs.physics_2d_update(&w, 1.0/60)} else {ecs.physics_3d_update(&w, 1.0/60)}
		after, _ := ecs.get_transform(&w, body)
		assert(before == after, "disabled body does not simulate")
		ecs.set_enabled(&w, parent, true)
	}
	assert(ecs.add(&w, r, parent, ecs.Lifetime{0}))
	ecs.update_lifetimes(&w, 1.0/60)
	assert(!ray(&w, dimension), "expiry cleans up native child bodies")
}
ray :: proc(w: ^ecs.World, dimension: int) -> bool {
	if dimension == 2 {_, hit := ecs.physics_2d_raycast(w, {0,0}, {20,0}); return hit}
	_, hit := ecs.physics_3d_raycast(w, {0,0,0}, {20,0,0})
	return hit
}

validate_rendering :: proc(r: ^ecs.Component_Registry) {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(800, 500, "Component rendering validation")
	defer rl.CloseWindow()
	w, ok := scene.load("examples/shapes_2d/scenes/main.scene.json", r)
	assert(ok)
	defer ecs.destroy(&w)
	manager := assets.init("examples/shapes_2d")
	defer assets.shutdown(&manager)
	target := rl.LoadRenderTexture(800,500)
	defer rl.UnloadRenderTexture(target)
	for enabled in ([]bool{true, false, true}) {
		ecs.set_enabled(&w, entity(&w,"group"), enabled)
		rl.BeginTextureMode(target)
		rl.ClearBackground(rl.WHITE)
		assert(render.draw_scene_2d(&w, &manager))
		rl.EndTextureMode()
		picture := rl.LoadImageFromTexture(target.texture)
		rl.ImageFlipVertical(&picture)
		assert(rl.GetImageColor(picture, 170, 200) == (rl.Color{45,115,215,255} if enabled else rl.WHITE), "rotated rectangle fill and activation")
		assert(rl.GetImageColor(picture, 400, 200) == (rl.Color{230,100,55,255} if enabled else rl.WHITE), "circle fill and activation")
		assert(rl.GetImageColor(picture, 630, 200) == rl.WHITE, "outline interior remains empty")
		assert(rl.GetImageColor(picture, 400, 70) == rl.WHITE, "disabled shape hidden")
		rl.UnloadImage(picture)
	}
}
main :: proc() {
	r := ecs.init_registry()
	defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	validate_activation(&r)
	validate_components(&r)
	validate_physics(&r, 2)
	validate_physics(&r, 3)
	for arg in os.args[1:] {if arg == "--runtime" {validate_rendering(&r); validate_audio(&r)}}
	fmt.println("Component activation, shapes, and lifetime validation passed")
}

assign_prefab_ids :: proc(w: ^ecs.World) {
	for id in ([]string{"inherited", "overridden"}) {
		parent := entity(w, id)
		child := ecs.child_entities(w, parent)[0]
		assert(ecs.set_entity_metadata(w, child, fmt.tprintf("%s-child", id), "", "", 1))
	}
}

validate_audio :: proc(r: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	add(&w, r, e, "AudioPlayer", `{
		"loop":{"sound":"assets/thruster.wav","volume":0,"looping":true},
		"music":{"sound":"assets/music.mp3","volume":0,"looping":true}
	}`)
	system := audio.init("examples/asteroids")
	defer audio.shutdown(&system)
	assert(system.available, "audio device required for runtime validation")
	for name in ([]string{"loop", "music"}) {assert(audio.play(&system, &w, e, name))}
	ecs.set_enabled(&w, e, false)
	audio.update(&system, &w)
	for name in ([]string{"loop", "music"}) {
		assert(!audio.is_playing(&system, e, name))
		assert(!audio.play(&system, &w, e, name), "cannot start disabled audio")
		assert(system.instances[ecs.Component_Instance{e, name}].suspended)
	}
	ecs.set_enabled(&w, e, true)
	audio.update(&system, &w)
	for name in ([]string{"loop", "music"}) {assert(audio.is_playing(&system, e, name), "resume suspended sound and stream")}
	ecs.set_enabled(&w, e, false)
	audio.update(&system, &w)
	for name in ([]string{"loop", "music"}) {assert(audio.stop(&system, e, name))}
	ecs.set_enabled(&w, e, true)
	audio.update(&system, &w)
	for name in ([]string{"loop", "music"}) {assert(!audio.is_playing(&system, e, name), "explicit stop cancels pending resume")}
	ecs.destroy_entity(&w, e)
	audio.update(&system, &w)
	assert(len(system.instances) == 0, "destroy releases audio resources")
}
