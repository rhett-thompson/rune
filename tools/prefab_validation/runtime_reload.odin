package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import rune "rune:core"
import "rune:ecs"
import "rune:scene"

runtime_reload_json :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}

validate_runtime_prefab_reload :: proc(registry: ^ecs.Component_Registry) {
	scene_file :: "build/runtime-reload.scene.json"
	prefab_file :: "build/runtime-reload.prefab.json"
	assert(os.write_entire_file(scene_file, `{"name":"Runtime reload","entities":[{"id":"player","components":{"Transform":{}}},{"id":"post","prefab":"runtime-reload.prefab.json"}]}`) == nil)
	write_runtime_reload_prefab(prefab_file, 0.2)
	w, loaded := scene.load(scene_file, registry)
	assert(loaded, scene.last_load_error())
	defer ecs.destroy(&w)
	player := required_entity(&w, "player")
	post := required_entity(&w, "post")
	generation := w.generation
	assert(ecs.set_transform(&w, player, {position = {7,8,9}, scale = {1,1,1}}))
	assert(ecs.set_enabled(&w, player, false))
	assert(ecs.set_entity_layer_mask(&w, player, 4))
	assert(ecs.add(&w, registry, player, ecs.Lifetime{seconds = 300}))
	// Exercise both anonymous and identified generated children, including JSON
	// strings and named component instances owned by the outgoing scene arena.
	generated := ecs.create_entity(&w)
	assert(ecs.set_parent(&w, generated, player))
	assert(ecs.add(&w, registry, generated, ecs.Transform{position = {1,2,3}, scale = {1,1,1}}))
	assert(ecs.add_component(&w, registry, generated, "PrefabMarker", runtime_reload_json(`{"payload":["generated",{"value":"retained"}]}`)))
	assert(ecs.add_component(&w, registry, generated, "AudioPlayer", runtime_reload_json(`{"hum":{"sound":"hum.wav","play_on_start":false}}`)))
	named := ecs.create_entity(&w)
	assert(ecs.set_entity_metadata(&w, named, "runtime", "Generated machine", "machine", 1))
	assert(ecs.set_parent(&w, named, post))
	assert(ecs.add(&w, registry, named, ecs.MeshRenderer{primitive = "cube", material = "generated.material.json"}))
	assert(ecs.add_component(&w, registry, post, "AudioPlayer", runtime_reload_json(`{"authored":{"sound":"authored.wav","play_on_start":false},"runtime":{"sound":"runtime.wav","play_on_start":false}}`)))
	entity_count := w.entity_count

	engine: rune.Engine
	engine.registry = registry^
	engine.project.hot_reload = {enabled = true, scenes = true, prefabs = true}
	engine.hot_reload_due = true
	engine.scene_watches = make(map[string]map[string]i64)
	defer {
		for path, watch in engine.scene_watches {rune.destroy_scene_watch(watch); delete(path)}
		delete(engine.scene_watches)
	}
	rune.watch_scene(&engine, scene_file)
	absolute, error := filepath.abs(prefab_file)
	assert(error == nil)
	defer delete(absolute)
	for index in 0 ..< 12 {
		radius := f32(index+1) / 10
		write_runtime_reload_prefab(prefab_file, radius)
		watch := engine.scene_watches[scene_file]
		watch[absolute] = -2
		assert(!rune.reload_scene_if_changed(&engine, &w, scene_file), "post-processing edits must not rebuild a generated world")
		assert(w.generation == generation && w.entity_count == entity_count)
		assert(required_entity(&w, "player") == player && required_entity(&w, "runtime") == named)
		assert(ecs.is_alive(&w, generated) && w.parents[generated] == player && w.parents[named] == post)
		pose, found := ecs.get_transform(&w, player)
		assert(found && pose.position == [3]f32{7,8,9}, "unrelated reload preserves player position")
		assert(!ecs.is_locally_enabled(&w, player) && w.layer_masks[player] == 4)
		assert(ecs.has_component_data(&w, player, "Lifetime"))
		value, ok := ecs.get(&w, post, ecs.PostProcessing)
		assert(ok && value.ssao.radius == radius && value.light_shafts.source == "player")
		payload := w.component_data["PrefabMarker"][generated].(json.Object)["payload"].(json.Array)
		assert(payload[0].(string) == "generated" && payload[1].(json.Object)["value"].(string) == "retained")
		assert(w.audio_players[{entity = generated, name = "hum"}].sound == "hum.wav")
		assert(w.audio_players[{entity = post, name = "runtime"}].sound == "runtime.wav")
		assert(w.component_instance_data["AudioPlayer"][{entity = post, name = "runtime"}].(json.Object)["sound"].(string) == "runtime.wav")
		assert(w.mesh_renderers[named].material == "generated.material.json")
	}
	// Membership changes remain structural, even when a matching component was
	// added at runtime. Reject removals without touching the current World.
	copy, ok := scene.load(scene_file, registry)
	assert(ok)
	assert(ecs.add(&copy, registry, required_entity(&copy, "player"), ecs.Lifetime{seconds = 300}))
	assert(!ecs.apply_value_snapshot(&w, &copy))
	ecs.destroy(&copy)
	copy, ok = scene.load(scene_file, registry)
	assert(ok)
	assert(ecs.remove_component(&copy, required_entity(&copy, "post"), "PostProcessing"))
	assert(!ecs.apply_value_snapshot(&w, &copy))
	ecs.destroy(&copy)
	copy, ok = scene.load(scene_file, registry)
	assert(ok)
	assert(ecs.destroy_entity(&copy, required_entity(&copy, "player")))
	assert(!ecs.apply_value_snapshot(&w, &copy))
	ecs.destroy(&copy)
	copy, ok = scene.load(scene_file, registry)
	assert(ok)
	assert(ecs.set_parent(&copy, required_entity(&copy, "post"), required_entity(&copy, "player")))
	assert(!ecs.apply_value_snapshot(&w, &copy))
	ecs.destroy(&copy)
	assert(w.generation == generation && w.entity_count == entity_count)
	// Production structural reload still replaces the World.
	assert(os.write_entire_file(prefab_file, `{"name":"Changed structure","components":{"Transform":{},"Camera3D":{}}}`) == nil)
	watch := engine.scene_watches[scene_file]
	watch[absolute] = -2
	assert(rune.reload_scene_if_changed(&engine, &w, scene_file))
	assert(w.generation != generation && !ecs.is_alive(&w, generated))
	validate_runtime_snapshot_ownership(registry)
	fmt.println("Runtime entities, player state, and repeated post-processing prefab reloads passed")
}

validate_runtime_snapshot_ownership :: proc(registry: ^ecs.Component_Registry) {
	heap: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap, context.allocator)
	defer mem.tracking_allocator_destroy(&heap)
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	{
		context.allocator = mem.tracking_allocator(&heap)
		context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
		w := ecs.init()
		post := ecs.create_entity(&w)
		assert(ecs.set_entity_metadata(&w, post, "post", "Post", "", 1))
		assert(ecs.add(&w, registry, post, ecs.default_post_processing()))
		ecs.capture_scene_source(&w)
		generated := ecs.create_entity(&w)
		assert(ecs.add_component(&w, registry, generated, "PrefabMarker", runtime_reload_json(`{"name":"owned runtime data"}`)))
		for i in 0 ..< 16 {
			copy := ecs.init()
			e := ecs.create_entity(&copy)
			assert(ecs.set_entity_metadata(&copy, e, "post", "Post", "", 1))
			value := ecs.default_post_processing()
			value.ssao.radius = f32(i+1)
			assert(ecs.add(&copy, registry, e, value))
			ecs.capture_scene_source(&copy)
			assert(ecs.apply_value_snapshot(&w, &copy))
			ecs.destroy(&copy)
			assert(w.component_data["PrefabMarker"][generated].(json.Object)["name"].(string) == "owned runtime data")
		}
		ecs.destroy(&w)
	}
	assert(len(heap.allocation_map) == 0, "repeated reloads must release scene baselines and runtime storage")
}

write_runtime_reload_prefab :: proc(path: string, radius: f32) {
	text := fmt.tprintf("%s%g%s", `{"name":"Environment","components":{"PostProcessing":{"ssao":{"enabled":true,"radius":`, radius, `},"light_shafts":{"source":"player"}},"AudioPlayer":{"authored":{"sound":"authored.wav","play_on_start":false}}}}`)
	assert(os.write_entire_file(path, text) == nil)
}
