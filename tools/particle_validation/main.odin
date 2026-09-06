package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "rune:assets"
import "rune:ecs"
import "rune:gizmos"
import "rune:particles"
import "rune:render"
import "rune:scene"
import rl "vendor:raylib"

Root :: "examples/particles_2d"
Scene :: Root + "/scenes/main.scene.json"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}

near :: proc(a, b: f32) -> bool {return math.abs(a - b) < 0.001}

validate_simulation :: proc(tracker: ^mem.Tracking_Allocator) {
	settings := particles.defaults()
	settings.max_particles = 4
	settings.emitting = false
	settings.lifetime = {2, 2}
	settings.speed = {10, 10}
	settings.angle = 0
	settings.spread = 0
	settings.gravity = {0, 4}
	settings.start_size, settings.end_size = 10, 2
	settings.start_color, settings.end_color = {200, 100, 0, 200}, {0, 100, 200, 0}
	state: particles.State
	defer particles.destroy(&state)
	assert(particles.emit(&state, settings, 3, {5, 7}) == 3)
	assert(particles.emit(&state, settings, 1000000000, {5, 7}) == 1)
	assert(len(state.particles) == 4 && cap(state.particles) == 4)
	assert(particles.emit(&state, settings, 1, {5, 7}) == 0)
	particles.update(&state, settings, 1, {500, 700})
	p := state.particles[0]
	assert(near(p.position[0], 15) && near(p.position[1], 9), "world space and acceleration")
	size, color := particles.appearance(p)
	assert(near(size, 6) && color == [4]u8{100, 100, 100, 100})
	particles.update(&state, settings, 1, {})
	assert(len(state.particles) == 0, "dead particles are reclaimed")
	before := tracker.total_allocation_count
	for _ in 0 ..< 100 {
		assert(particles.emit(&state, settings, 4, {}) == 4)
		particles.update(&state, settings, 2, {})
	}
	assert(tracker.total_allocation_count == before, "storage reused without per-frame heap allocations")
	settings.emitting, settings.rate = true, 4
	particles.update(&state, settings, 0.125, {})
	assert(len(state.particles) == 0)
	particles.update(&state, settings, 0.125, {})
	assert(len(state.particles) == 1 && near(state.particles[0].age, 0))
	particles.clear(&state)
	particles.update(&state, settings, 1, {})
	assert(len(state.particles) == 4)
	assert(near(state.particles[0].age, 0.75) && near(state.particles[3].age, 0))
	settings.emitting = false
	particles.update(&state, settings, 2, {})
	settings.emitting = true
	particles.update(&state, settings, 0.125, {})
	assert(len(state.particles) == 0, "stopping does not queue births")
	particles.update(&state, settings, 0, {})
	particles.update(&state, settings, -1, {})
	assert(len(state.particles) == 0)
	particles.clear(&state)
	settings.lifetime = {1, 1}
	particles.update(&state, settings, 1000000, {})
	assert(len(state.particles) <= 4, "large dt stays bounded")
	particles.clear(&state)
	settings.spread = 360
	settings.speed = {10, 50}
	assert(particles.emit(&state, settings, 1, {}) == 1)
	first := state.particles[0]
	particles.clear(&state)
	assert(particles.emit(&state, settings, 1, {}) == 1 && first == state.particles[0], "seeded replay")
}

validate_components :: proc(registry: ^ecs.Component_Registry) {
	world, ok := scene.load(Scene, registry)
	assert(ok, scene.last_load_error())
	defer ecs.destroy(&world)
	entity, _ := ecs.find_entity_by_id(&world, "burst")
	emitter, found := ecs.get(&world, entity, ecs.ParticleEmitter2D)
	assert(found && !emitter.emitting && emitter.seed == 83)
	assert(ecs.emit_particles_2d(&world, entity, 3) == 3)
	version := ecs.change_version(&world)
	invalid := []string{
		`{"unknown": 1}`, `{"max_particles": 0}`, `{"max_particles": 65537}`,
		`{"max_particles": 1.5}`, `{"rate": -1}`, `{"rate": 100001}`,
		`{"lifetime": [0, 1]}`, `{"lifetime": [2, 1]}`, `{"speed": [2, 1]}`,
		`{"spread": 361}`, `{"start_size": -1}`, `{"end_color": [0, 0, 0, 256]}`,
		`{"gravity": [1]}`, `{"texture": 42}`, `{"emitting": 1}`, `{"seed": -1}`,
		`{"seed": 4294967296}`, `{"rate": null}`, `{"end_color": [0, 0, 0, 1.5]}`,
		`{"speed": [null, 100]}`,
	}
	for text in invalid {
		assert(!ecs.add_component(&world, registry, entity, "ParticleEmitter2D", parse(text)), text)
	}
	assert(ecs.change_version(&world) == version && ecs.particle_count_2d(&world, entity) == 3)
	assert(!ecs.set_runtime_field(&world, registry, entity, "ParticleEmitter2D", "rate", parse("-5")))
	assert(ecs.set_runtime_field(&world, registry, entity, "ParticleEmitter2D", "speed", parse("[2,4]")))
	assert(ecs.particle_count_2d(&world, entity) == 3, "appearance and speed edits preserve particles")
	data, serialized := ecs.runtime_component_json(&world, entity, "ParticleEmitter2D")
	assert(serialized)
	object := data.(json.Object)
	_, has_particles := object["particles"]
	assert(!has_particles && object["seed"].(json.Integer) == 83)
	assert(ecs.add_component(&world, registry, entity, "ParticleEmitter2D", data), "serialization round trip")
	assert(ecs.particle_count_2d(&world, entity) == 3)
	emitter, _ = ecs.get(&world, entity, ecs.ParticleEmitter2D)
	emitter.max_particles = 8
	assert(ecs.set(&world, entity, emitter))
	assert(ecs.particle_count_2d(&world, entity) == 0)
	assert(ecs.emit_particles_2d(&world, entity, 100) == 8)
	emitter.seed = 8
	assert(ecs.set(&world, entity, emitter) && ecs.particle_count_2d(&world, entity) == 0)
	assert(ecs.emit_particles_2d(&world, entity, 1) == 1)
	// A value reload must not adopt or free another World's runtime pools.
	snapshot, loaded := scene.load(Scene, registry)
	assert(loaded)
	other, _ := ecs.find_entity_by_id(&snapshot, "burst")
	assert(ecs.set(&snapshot, other, emitter))
	assert(ecs.set_runtime_field(&snapshot, registry, other, "ParticleEmitter2D", "texture", parse(`"assets/soft.png"`)))
	assert(ecs.apply_value_snapshot(&world, &snapshot))
	ecs.destroy(&snapshot)
	emitter, _ = ecs.get(&world, entity, ecs.ParticleEmitter2D)
	assert(emitter.texture == "assets/soft.png" && ecs.particle_count_2d(&world, entity) == 1)
	assert(ecs.remove_component(&world, entity, "ParticleEmitter2D"))
	assert(ecs.particle_count_2d(&world, entity) == 0 && ecs.emit_particles_2d(&world, entity, 1) == 0)
	assert(ecs.add(&world, registry, entity, ecs.default_particle_emitter_2d()), "code-first add")
	assert(ecs.emit_particles_2d(&world, entity, 2) == 2)
	assert(ecs.destroy_entity(&world, entity))
	assert(ecs.emit_particles_2d(&world, entity, 2) == 0 && ecs.particle_count_2d(&world, entity) == 0)
}

validate_hierarchy :: proc(registry: ^ecs.Component_Registry) {
	world := ecs.init()
	defer ecs.destroy(&world)
	parent := ecs.create_entity(&world)
	child := ecs.create_entity(&world)
	assert(ecs.add_component(&world, registry, parent, "Transform", parse(`{"position":[100,20,0],"scale":[2,3,1],"rotation":[0,0,90]}`)))
	assert(ecs.add_component(&world, registry, child, "Transform", parse(`{"position":[10,5,0]}`)))
	assert(ecs.set_parent(&world, child, parent))
	settings := ecs.default_particle_emitter_2d()
	settings.angle, settings.spread = 0, 0
	settings.speed = {10, 10}
	assert(ecs.add(&world, registry, child, settings))
	assert(ecs.emit_particles_2d(&world, child, 1) == 1)
	p := world.particle_states_2d[child].particles[0]
	assert(p.position == [2]f32{120, 35} && near(p.velocity[0], 0) && near(p.velocity[1], 10))
	assert(near(p.start_size, settings.start_size * 3))
}

validate_rendering :: proc(registry: ^ecs.Component_Registry) {
	rl.SetConfigFlags({.WINDOW_HIDDEN, .WINDOW_HIGHDPI})
	rl.InitWindow(960, 550, "Particle validation")
	defer rl.CloseWindow()
	world, ok := scene.load(Scene, registry)
	assert(ok)
	defer ecs.destroy(&world)
	manager := assets.init(Root)
	defer assets.shutdown(&manager)
	for _ in 0 ..< 60 {ecs.update_particles_2d(&world, 1.0 / 60)}
	entity, _ := ecs.find_entity_by_id(&world, "fountain")
	before := world.particle_states_2d[entity].particles[0]
	count := ecs.particle_count_2d(&world, entity)
	for _ in 0 ..< 3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		assert(render.draw_scene_2d(&world, &manager))
		rl.EndDrawing()
	}
	assert(ecs.particle_count_2d(&world, entity) == count && world.particle_states_2d[entity].particles[0] == before, "render never advances simulation")
	validate_dpi_alignment(&world, &manager)
}

// Check actual pixels against raylib's logical world-to-screen coordinates,
// including camera translation/rotation/zoom and drawing into a render texture.
validate_dpi_alignment :: proc(world: ^ecs.World, manager: ^assets.Asset_Manager) {
	for entity in ecs.query(world, ecs.ParticleEmitter2D) {
		emitter, _ := ecs.get(world, entity, ecs.ParticleEmitter2D)
		emitter.emitting = false
		assert(ecs.set(world, entity, emitter))
		ecs.clear_particles_2d(world, entity)
	}
	entity, _ := ecs.find_entity_by_id(world,"fountain")
	emitter, _ := ecs.get(world,entity,ecs.ParticleEmitter2D)
	emitter.start_color, emitter.end_color = {255,0,0,255}, {255,0,0,255}
	emitter.start_size, emitter.end_size = 12, 12
	emitter.additive = false
	assert(ecs.set(world,entity,emitter))
	assert(ecs.emit_particles_2d(world,entity,1)==1)
	camera_entity, component, _ := ecs.active_camera_2d(world)
	transform, _ := ecs.get_transform(world,camera_entity)
	transform.position = {50,70,0}
	component.offset, component.zoom, component.rotation = {40,60}, 1.25, 20
	assert(ecs.set_transform(world,camera_entity,transform))
	assert(ecs.set(world,camera_entity,component))
	camera := rl.Camera2D{target={50,70},offset={40,60},zoom=1.25,rotation=20}
	point := rl.GetWorldToScreen2D({200,410},camera)
	for _ in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		assert(render.draw_scene_2d(world,manager))
		// A UI reference at the same logical x, below the emitter.
		rl.DrawCircleV(point+rl.Vector2{0,24},4,rl.GREEN)
		rl.EndDrawing()
	}
	capture := rl.LoadImageFromScreen()
	sx := f32(capture.width)/f32(rl.GetScreenWidth())
	sy := f32(capture.height)/f32(rl.GetScreenHeight())
	assert(rl.GetImageColor(capture,i32(point.x*sx),i32(point.y*sy))==rl.Color{255,0,0,255},"particle aligns with logical UI coordinates at display DPI")
	assert(rl.GetImageColor(capture,i32(point.x*sx),i32((point.y+24)*sy))==rl.GREEN,"screen-space reference uses the same scale")
	rl.UnloadImage(capture)
	for _ in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		assert(gizmos.draw_scene_2d(world,{enabled=true,transforms=true}))
		rl.EndDrawing()
	}
	capture = rl.LoadImageFromScreen()
	// The white transform center is covered partly by red/green axis lines.
	assert(rl.GetImageColor(capture,i32(point.x*sx),i32(point.y*sy))!=rl.BLACK,"gizmos align with the camera and UI")
	rl.UnloadImage(capture)
	target := rl.LoadRenderTexture(960,550)
	defer rl.UnloadRenderTexture(target)
	rl.BeginTextureMode(target)
	rl.ClearBackground(rl.BLACK)
	assert(render.draw_scene_2d(world,manager))
	rl.EndTextureMode()
	capture = rl.LoadImageFromTexture(target.texture)
	// OpenGL render textures are vertically flipped in image readback.
	assert(rl.GetImageColor(capture,i32(point.x),capture.height-1-i32(point.y))==rl.Color{255,0,0,255},"offscreen rendering does not apply display DPI")
	rl.UnloadImage(capture)
}

main :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	context.allocator = mem.tracking_allocator(&tracker)
	{
		registry := ecs.init_registry()
		assert(ecs.register_builtin_components(&registry))
		defer ecs.destroy_registry(&registry)
		validate_simulation(&tracker)
		validate_components(&registry)
		validate_hierarchy(&registry)
		for arg in os.args[1:] {if arg == "--runtime" {validate_rendering(&registry)}}
	}
	assert(len(tracker.bad_free_array) == 0 && tracker.current_memory_allocated == 0)
	fmt.println("Particles: emission, bounded reuse, deterministic bursts, lifetime, hierarchy, JSON, edits, reload and cleanup passed")
}
