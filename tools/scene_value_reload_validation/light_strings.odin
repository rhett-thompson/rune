package main

import "core:mem"
import "core:testing"
import "rune:ecs"

@(test)
light_string_reload_test :: proc(t: ^testing.T) {
	validate_light_string_reload()
}

light_reload_fixture :: proc(registry: ^ecs.Component_Registry) -> (ecs.World, ecs.Entity) {
	world, entity := runtime_reload_fixture(registry)
	assert(ecs.add(&world, registry, entity, ecs.default_post_processing()))
	for component in ([]string{"DirectionalLight", "PointLight", "SpotLight"}) {
		light := ecs.create_entity(&world)
		assert(ecs.set_entity_metadata(&world, light, component, component, "", 1))
		set_component_json(&world, light, component, `{"shadow_profile":"assets/authored.shadow.json","shadow_overrides":{"update_mode":"interval"}}`)
		assert(ecs.add_component(&world, registry, light, component, world.component_data[component][light]))
	}
	ecs.capture_scene_source(&world)
	return world, entity
}

assert_live_light_string :: proc(tracker: ^mem.Tracking_Allocator, value, expected: string) {
	pointer := uintptr(raw_data(value))
	allocated := false
	for _, allocation in tracker.allocation_map {
		start := uintptr(allocation.memory)
		if pointer >= start && pointer + uintptr(len(value)) <= start + uintptr(allocation.size) {
			allocated = true
			break
		}
	}
	assert(allocated, "light strings must remain in live storage after scene reload")
	assert(value == expected)
}

validate_light_string_reload :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_light_string_storage(&tracker)
	assert(len(tracker.bad_free_array) == 0 && tracker.current_memory_allocated == 0)
}

validate_light_string_storage :: proc(tracker: ^mem.Tracking_Allocator) {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, entity := light_reload_fixture(&registry)
	defer ecs.destroy(&world)
	runtime_lights: [3]ecs.Entity
	for component, i in ([]string{"DirectionalLight", "PointLight", "SpotLight"}) {
		runtime_lights[i] = ecs.create_entity(&world)
		set_component_json(&world, runtime_lights[i], component, `{"shadow_profile":"assets/runtime.shadow.json","shadow_overrides":{"update_mode":"manual"}}`)
		assert(ecs.add_component(&world, &registry, runtime_lights[i], component, world.component_data[component][runtime_lights[i]]))
	}
	for pass in 0 ..< 8 {
		snapshot, other := light_reload_fixture(&registry)
		assert(ecs.set_runtime_field(&snapshot, &registry, other, "PostProcessing", "film_grain.enabled", pass % 2 == 0))
		// Include a changed light as well as untouched authored/runtime lights.
		changed, _ := ecs.find_entity_by_id(&snapshot, "PointLight")
		assert(ecs.set_runtime_field(&snapshot, &registry, changed, "PointLight", "intensity", i64(pass + 1)))
		assert(ecs.apply_value_snapshot(&world, &snapshot))
		ecs.destroy(&snapshot)
		for component, i in ([]string{"DirectionalLight", "PointLight", "SpotLight"}) {
			authored, found := ecs.find_entity_by_id(&world, component)
			assert(found)
			for light, j in ([2]ecs.Entity{authored, runtime_lights[i]}) {
				profile, mode: string
				switch component {
				case "DirectionalLight": value := world.directional_lights[light]; profile = value.shadow_profile; mode, _ = value.shadow_overrides.update_mode.(string)
				case "PointLight": value := world.point_lights[light]; profile = value.shadow_profile; mode, _ = value.shadow_overrides.update_mode.(string)
				case "SpotLight": value := world.spot_lights[light]; profile = value.shadow_profile; mode, _ = value.shadow_overrides.update_mode.(string)
				}
				assert_live_light_string(tracker, profile, "assets/authored.shadow.json" if j == 0 else "assets/runtime.shadow.json")
				assert_live_light_string(tracker, mode, "interval" if j == 0 else "manual")
			}
		}
		post, found := ecs.get_post_processing(&world, entity)
		assert(found && post.film_grain.enabled == (pass % 2 == 0))
	}
}
