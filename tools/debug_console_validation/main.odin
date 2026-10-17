package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
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
	assert(console.execute(&game.console, "memory"))
	memory_result := game.console.result_data.(json.Object)
	assert(memory_result["world"].(json.Object)["entity_count"].(json.Integer) == 1)
	assert(memory_result["world"].(json.Object)["map_bytes"].(json.Integer) > 0)
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
	validate_navmesh_commands(&registry)
	validate_argument_completion(&registry)
	fmt.println("Debug commands, runtime edits, and deterministic stepping validation passed")
	for argument in os.args[1:] {
		if argument == "--runtime" {validate_debug_picking_view(&registry)}
	}
}

completion_line :: proc(dev: ^console.Console, text: string) {
	console.edit(dev, .Select_All)
	assert(console.insert_text(dev, text))
}

expect_completion :: proc(dev: ^console.Console, expected: string, reverse := false) {
	assert(console.complete(dev, reverse), expected)
	assert(string(dev.input[:dev.input_len]) == expected, string(dev.input[:dev.input_len]))
}

validate_argument_completion :: proc(registry: ^ecs.Component_Registry) {
	world := ecs.init()
	defer ecs.destroy(&world)
	player := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, player, "player", "", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, registry, player, "Transform", parse(`{}`)))
	assert(ecs.add_component(&world, registry, player, "Custom", parse(`{}`)))
	spaced := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, spaced, "player two", "", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, registry, spaced, "Transform", parse(`{}`)))
	assert(ecs.register_data_component(registry, "Debug extra"))
	assert(ecs.add_component(&world, registry, spaced, "Debug extra", parse(`{"value":false}`)))
	quoted := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, quoted, `quoted"one`, "", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, registry, quoted, "Custom", parse(`{}`)))
	nav := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, nav, "navigation", "", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, registry, nav, "NavMesh3D", parse(`{"asset":"course.navmesh.json"}`)))
	unnamed := ecs.create_entity(&world)
	controls, loaded := input.load("examples/tilemap_2d/input/default.input.json")
	assert(loaded)
	defer input.destroy(&controls)
	controls.mappings.actions["open menu"] = controls.mappings.actions["move_right"]
	game := rune.Engine{console = console.init(), registry = registry^, input = controls}
	rune.register_debug_commands(&game.console)
	rune.bind_debug_console(&game, &world)
	dev := &game.console
	log_sequence, errors := dev.log_sequence, dev.error_count
	completion_line(dev, "inspect pla")
	expect_completion(dev, "inspect player")
	expect_completion(dev, `inspect "player two"`)
	expect_completion(dev, "inspect player", true)
	completion_line(dev, "inspect player C")
	expect_completion(dev, "inspect player Custom")
	completion_line(dev, "inspect player Camera3")
	assert(!console.complete(dev), "inspect offers only attached components")
	completion_line(dev, `inspect "player two" Debug`)
	expect_completion(dev, `inspect "player two" "Debug extra"`)
	completion_line(dev, "entities Camera3")
	expect_completion(dev, "entities Camera3D")
	completion_line(dev, "set player Tr")
	expect_completion(dev, "set player Transform.position")
	completion_line(dev, "set player Transform.position.")
	expect_completion(dev, "set player Transform.position.0")
	expect_completion(dev, "set player Transform.position.1")
	expect_completion(dev, "set player Transform.position.0", true)
	completion_line(dev, "set player Custom.")
	expect_completion(dev, "set player Custom.label")
	expect_completion(dev, "set player Custom.speed")
	completion_line(dev, "input move_r")
	expect_completion(dev, "input move_right")
	completion_line(dev, "input move_right re")
	expect_completion(dev, "input move_right release")
	completion_line(dev, "input open")
	expect_completion(dev, `input "open menu"`)
	completion_line(dev, "window b")
	expect_completion(dev, "window borderless")
	completion_line(dev, "navmesh o")
	expect_completion(dev, "navmesh off")
	expect_completion(dev, "navmesh on")
	completion_line(dev, "navmesh on n")
	expect_completion(dev, "navmesh on navigation")
	completion_line(dev, "navmesh off n")
	assert(!console.complete(dev))
	completion_line(dev, fmt.tprintf("enable @%d", u64(unnamed)))
	assert(!console.complete(dev), "an exact single candidate leaves input intact")
	completion_line(dev, "disable @")
	expect_completion(dev, fmt.tprintf("disable @%d", u64(unnamed)))
	assert(dev.log_sequence == log_sequence && dev.error_count == errors, "completion does not execute commands or log errors")
	// Quoted candidates must remain executable by all consumers, including the
	// inspect reply generated internally by set.
	completion_line(dev, "inspect player t")
	assert(!console.complete(dev))
	completion_line(dev, "inspect \"player tw")
	expect_completion(dev, `inspect "player two"`)
	console.execute(dev, string(dev.input[:dev.input_len]))
	assert(dev.result_data.(json.Object)["entity"].(json.Object)["id"].(json.String) == "player two")
	console.execute(dev, `set "quoted\"one" Custom.speed 5`)
	assert(dev.result_data.(json.Object)["entity"].(json.Object)["id"].(json.String) == `quoted"one`)
	completion_line(dev, `set "player two" Debug`)
	expect_completion(dev, `set "player two" "Debug extra.value"`)
	console.execute(dev, `set "player two" "Debug extra.value" true`)
	assert(dev.result_data.(json.Object)["components"].(json.Object)["Debug extra"].(json.Object)["value"].(json.Boolean))
	for command in ([]string{`inspect "player two" Debug extra`, `inspect "player two" "Debug extra"`}) {
		console.execute(dev, command)
		assert(dev.result_data.(json.Object)["components"].(json.Object)["Debug extra"].(json.Object)["value"].(json.Boolean))
	}
	completion_line(dev, "entities Debug")
	expect_completion(dev, `entities "Debug extra"`)
	console.execute(dev, string(dev.input[:dev.input_len]))
	assert(len(dev.result_data.(json.Array)) == 1)
	console.execute(dev, "entities Debug extra")
	assert(len(dev.result_data.(json.Array)) == 1)
	console.execute(dev, `input "open menu" press`)
	assert(game.input.injected["open menu"].down)
	console.execute(dev, `disable "player two"`)
	assert(!ecs.is_locally_enabled(&world, spaced))
	console.execute(dev, `enable "player two"`)
	assert(ecs.is_locally_enabled(&world, spaced))
	assert(dev.error_count == errors)
	for command in ([]string{
		`entities "Debug extra" junk`, `entities "Debug extra"junk`,
		`inspect "player two" "Debug extra" junk`, `inspect "player two" "Debug extra\uZZZZ"`,
	}) {
		before := dev.error_count
		console.execute(dev, command)
		assert(dev.error_count == before+1, "malformed quoted components must be rejected in full")
	}
	errors = dev.error_count
	// Repeated Tab reacquires live data even when the previous candidate is
	// removed, then a completely different World is bound before the next Tab.
	fresh := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, fresh, "fresh_a", "", "", ecs.Default_Layer_Mask))
	completion_line(dev, "inspect fresh")
	expect_completion(dev, "inspect fresh_a")
	assert(ecs.destroy_entity(&world, fresh))
	fresh = ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, fresh, "fresh_b", "", "", ecs.Default_Layer_Mask))
	expect_completion(dev, "inspect fresh_b")
	replacement := ecs.init()
	defer ecs.destroy(&replacement)
	fresh = ecs.create_entity(&replacement)
	assert(ecs.set_entity_metadata(&replacement, fresh, "fresh_c", "", "", ecs.Default_Layer_Mask))
	rune.bind_debug_console(&game, &replacement)
	expect_completion(dev, "inspect fresh_c")
	rune.bind_debug_console(&game, nil)
	assert(!console.complete(dev))
	assert(dev.error_count == errors, "completion without a World stays quiet")
}

validate_navmesh_commands :: proc(registry: ^ecs.Component_Registry) {
	world := ecs.init()
	defer ecs.destroy(&world)
	nav := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, nav, "navigation", "Navigation", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, registry, nav, "NavMesh3D", parse(`{"asset":"course.navmesh.json"}`)))
	game := rune.Engine{console = console.init()}
	defer delete(game.debug.navmesh_entity)
	rune.register_debug_commands(&game.console)
	rune.bind_debug_console(&game, &world)
	// Command arguments are borrowed from an inbox/interactive buffer. Filters
	// must survive buffer reuse and a scene World replacement with the same ID.
	command := "navmesh on navigation"
	buffer: [64]u8
	copy(buffer[:], command)
	assert(console.execute(&game.console, string(buffer[:len(command)])))
	for &byte in buffer {byte = 0}
	assert(game.gizmos.navmeshes && !game.gizmos.enabled && game.gizmos.navmesh_entity == "navigation")
	for invalid in ([]string{"navmesh toggle", "navmesh off navigation", "navmesh on navigation extra", "navmesh on missing"}) {
		errors := game.console.error_count
		assert(console.execute(&game.console, invalid))
		assert(game.console.error_count == errors + 1)
		assert(game.gizmos.navmeshes && game.gizmos.navmesh_entity == "navigation", "invalid commands retain the display setting")
	}
	replacement := ecs.init()
	defer ecs.destroy(&replacement)
	nav = ecs.create_entity(&replacement)
	assert(ecs.set_entity_metadata(&replacement, nav, "navigation", "Navigation", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&replacement, registry, nav, "NavMesh3D", parse(`{"asset":"course.navmesh.json"}`)))
	rune.bind_debug_console(&game, &replacement)
	assert(console.execute(&game.console, "navmesh"))
	result := game.console.result_data.(json.Object)
	assert(result["enabled"].(json.Boolean) && result["entity"].(json.String) == "navigation")
	assert(console.execute(&game.console, "navmesh on"))
	assert(game.gizmos.navmeshes && game.gizmos.navmesh_entity == "")
	assert(console.execute(&game.console, "navmesh off"))
	assert(!game.gizmos.navmeshes && game.debug.navmesh_entity == "")
	errors := game.console.error_count
	console.execute(&game.console, "navmesh on navigation_missing")
	assert(game.console.error_count == errors + 1 && !game.gizmos.navmeshes)
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
