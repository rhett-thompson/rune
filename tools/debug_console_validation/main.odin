package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:scene"

Custom :: struct {speed: f32, label: string}

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}

main :: proc() {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	assert(ecs.register_component(&registry, "Custom", Custom, Custom{speed = 2, label = "test"}, "Test component"))
	world := ecs.init()
	defer ecs.destroy(&world)
	entity := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, entity, "player", "Player", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, &registry, entity, "Transform", parse(`{"position":[1,2,3]}`)))
	assert(ecs.add_component(&world, &registry, entity, "SpriteRenderer", parse(`{"texture":"example.png"}`)))
	assert(ecs.add_component(&world, &registry, entity, "Camera2D", parse(`{"active":true}`)))
	assert(ecs.add_component(&world, &registry, entity, "Custom", parse(`{}`)))
	assert(ecs.set_transform(&world, entity, ecs.Transform{position = {10,20,30}, scale = {1,1,1}}))
	data, valid := ecs.runtime_component_json(&world, entity, "Transform")
	coordinate, _ := ecs.read_number(data.(json.Object)["position"].(json.Array)[0])
	assert(valid && coordinate == 10)
	assert(ecs.set_runtime_field(&world, &registry, entity, "Transform", "position.0", parse("50")))
	transform, _ := ecs.get_transform(&world, entity)
	assert(transform.position == {50,20,30}, "field edits must preserve current sibling values")
	assert(!ecs.set_runtime_field(&world, &registry, entity, "Transform", "position", parse("false")))
	assert(!ecs.set_runtime_field(&world, &registry, entity, "Transform", "missing", parse("1")))
	unchanged, _ := ecs.get_transform(&world, entity)
	assert(unchanged == transform, "invalid edits must be atomic")
	assert(ecs.set_runtime_field(&world, &registry, entity, "SpriteRenderer", "tint", parse("[1,2,3,255]")))
	sprite, _ := ecs.get_sprite_renderer(&world, entity)
	assert(sprite.tint == {1,2,3,255} && sprite.texture == "example.png")
	assert(ecs.set_typed_component(&world, entity, "Custom", Custom{speed = 4, label = "runtime"}))
	assert(ecs.set_runtime_field(&world, &registry, entity, "Custom", "speed", parse("8")))
	custom, _ := ecs.get_typed_component(&world, entity, "Custom", Custom)
	assert(custom.speed == 8 && custom.label == "runtime")
	assert(!ecs.set_runtime_field(&world, &registry, entity, "Custom", "speed", parse(`"wrong"`)))

	controls, loaded := input.load("examples/tilemap_2d/input/default.input.json")
	assert(loaded)
	defer input.destroy(&controls)
	game := rune.Engine {
		registry = registry,
		console = console.init(),
		input = controls,
		fixed_delta_time = 1.0/60.0,
	}
	rune.register_debug_commands(&game.console)
	rune.bind_debug_console(&game, &world)
	assert(console.execute(&game.console, "inspect player Transform"))
	coordinate, _ = ecs.read_number(game.console.result_data.(json.Object)["components"].(json.Object)["Transform"].(json.Object)["position"].(json.Array)[0])
	assert(coordinate == 50)
	assert(console.execute(&game.console, "entities Camera2D"))
	assert(len(game.console.result_data.(json.Array)) == 1)
	console.execute(&game.console, "pause")
	assert(game.debug.paused && !rune.debug_simulation_tick(&game))
	console.execute(&game.console, "input move_right press")
	assert(!rune.debug_simulation_tick(&game))
	console.execute(&game.console, "step 3")
	assert(game.console.defer_reply)
	for index in 0..<3 {
		assert(rune.debug_simulation_tick(&game))
		assert(input.pressed(&game.input, "move_right") == (index == 0))
		assert(input.axis(&game.input, "move_x") == 1)
		rune.run_fixed_pipeline(&game, &world)
		rune.debug_simulation_finished(&game)
	}
	assert(game.debug.fixed_steps == 3 && game.debug.simulation_updates == 3)
	assert(math.abs(game.debug.simulation_time - 0.05) < 0.000001)
	assert(!game.console.defer_reply && game.debug.paused && !rune.debug_simulation_tick(&game))
	console.execute(&game.console, "input move_right release")
	console.execute(&game.console, "step")
	assert(rune.debug_simulation_tick(&game) && input.released(&game.input, "move_right"))
	rune.debug_simulation_finished(&game)
	console.execute(&game.console, "input move_right clear")
	assert(len(game.input.injected) == 0)
	before := game.console.error_count
	console.execute(&game.console, "step -1")
	assert(game.console.error_count == before + 1 && !game.console.defer_reply)
	console.execute(&game.console, "resume")
	assert(!game.debug.paused)
	before = game.console.error_count
	console.execute(&game.console, "step")
	assert(game.console.error_count == before + 1)
	sequence := game.console.log_sequence
	console.error(&game.console, "test error")
	logs := console.read_logs(&game.console, sequence)
	assert(len(logs.entries) == 1 && logs.entries[0].level == "error" && logs.next_sequence > sequence)
	for _ in 0..<70 {console.info(&game.console, "overflow")}
	assert(logs.entries[0].message == "test error", "log snapshots must survive ring buffer reuse")
	assert(console.read_logs(&game.console, sequence).truncated)
	// Verify built-in runtime snapshots can be deserialized by the ordinary
	// scene path, including tilemaps, named audio instances, colors and bodies.
	paths := []string{
		"examples/tilemap_2d/scenes/main.scene.json",
		"examples/hello_3d/scenes/main.scene.json",
		"examples/box3d_balls/scenes/main.scene.json",
		"examples/textured_model_3d/scenes/main.scene.json",
		"examples/audio_components/scenes/main.scene.json",
	}
	for path in paths {
		source, scene_ok := scene.load(path, &registry)
		assert(scene_ok)
		defer ecs.destroy(&source)
		target := ecs.init()
		defer ecs.destroy(&target)
		for source_entity in source.entities {
			target_entity := ecs.create_entity(&target)
			for name in source.component_data {
				if !ecs.has_component_data(&source, source_entity, name) {continue}
				value, snapshot_ok := ecs.runtime_component_json(&source, source_entity, name)
				assert(snapshot_ok, name)
				assert(ecs.add_component(&target, &registry, target_entity, name, value), name)
			}
		}
	}
	validate_snapshot_ownership(&registry, paths)
	fmt.println("Debug commands, runtime edits, and deterministic stepping validation passed")
}

validate_snapshot_ownership :: proc(registry: ^ecs.Component_Registry, paths: []string) {
	heap: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap, context.allocator)
	defer mem.tracking_allocator_destroy(&heap)
	heap_allocator := mem.tracking_allocator(&heap)
	scratch, retained: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	mem.dynamic_arena_init(&retained)
	defer mem.dynamic_arena_destroy(&scratch)
	defer mem.dynamic_arena_destroy(&retained)
	allocator := mem.dynamic_arena_allocator(&retained)
	Snapshot :: struct {value: json.Value, encoded: string}
	snapshots := make([dynamic]Snapshot, allocator)
	{
		context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
		for path in paths {
			world, loaded := scene.load(path, registry)
			assert(loaded)
			for entity in world.entities {
				for name in world.component_data {
					if !ecs.has_component_data(&world, entity, name) {continue}
					value, ok := ecs.runtime_component_json(&world, entity, name, allocator)
					assert(ok, name)
					encoded, err := json.marshal(value, allocator = allocator)
					assert(err == nil)
					append(&snapshots, Snapshot{value, string(encoded)})
					heap_value, heap_ok := ecs.runtime_component_json(&world, entity, name, heap_allocator)
					assert(heap_ok, name)
					json.destroy_value(heap_value, heap_allocator)
					assert(len(heap.allocation_map) == 0, "snapshot must free completely with its output allocator")
				}
			}
			ecs.destroy(&world)
		}
	}
	mem.dynamic_arena_reset(&scratch)
	for snapshot in snapshots {
		// Compare parsed values because object key ordering is not part of JSON.
		expected := parse(snapshot.encoded)
		assert(ecs.json_values_equal(snapshot.value, expected), "retained snapshot must outlive its World and frame")
	}
}
