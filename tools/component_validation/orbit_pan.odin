package main

import "core:encoding/json"
import "core:math"
import "core:strings"
import "rune:ecs"
import "rune:input"
import "rune:scene"

pan_near :: proc(a, b: [3]f32) -> bool {
	for value, i in a {if math.abs(value - b[i]) > 0.0001 {return false}}
	return true
}

validate_orbit_pan :: proc() {
	controls, loaded := input.load("examples/skeletal_animation_3d/input/default.input.json")
	assert(loaded)
	defer input.destroy(&controls)
	assert(controls.mappings.actions["pan_camera"][0].button == "MIDDLE")
	controls.axes["pan_x"], controls.axes["pan_y"] = 100, 50
	orbit := ecs.default_orbit_camera_3d()
	orbit.pan_action = "pan_camera"
	orbit.yaw, orbit.pitch, orbit.distance = 90, 0, 10
	before := ecs.update_orbit_camera_3d(&orbit, &controls, 0)
	assert(orbit.target == [3]f32{}, "mouse motion alone does not pan")
	controls.actions["pan_camera"] = {is_down = true}
	controls.actions["orbit_camera"] = {is_down = true}
	controls.axes["orbit_x"], controls.axes["orbit_y"] = 75, 30
	orbit.auto_yaw_speed = 45
	initial := orbit
	after := ecs.update_orbit_camera_3d(&orbit, &controls, 1.0 / 60.0)
	assert(pan_near(orbit.target, {-1.5, 0.75, 0}), "drag follows the pointer horizontally and vertically")
	assert(pan_near(after.position - before.position, orbit.target - initial.target), "camera and target translate together")
	assert(orbit.yaw == initial.yaw && orbit.pitch == initial.pitch && orbit.distance == initial.distance,
	       "pan takes priority over manual and automatic orbit without changing zoom")
	faster := initial
	ecs.update_orbit_camera_3d(&faster, &controls, 1.0 / 240.0)
	assert(pan_near(faster.target, orbit.target), "mouse pan is independent of frame duration")
	farther := initial
	farther.distance *= 2
	ecs.update_orbit_camera_3d(&farther, &controls, 1.0 / 60.0)
	assert(pan_near(farther.target, orbit.target * 2), "pan scales with orbit distance")
	angled := initial
	angled.yaw, angled.pitch = 0, 45
	angled_before := ecs.update_orbit_camera_3d(&angled, &controls, 0)
	assert(angled.target[0] < 0 && angled.target[1] > 0 && angled.target[2] > 0,
	       "pan axes follow the tilted camera rather than fixed world axes")
	direction := angled_before.position - angled.target
	dot: f32
	for value, i in angled.target {dot += value * direction[i]}
	assert(math.abs(dot) < 0.0001, "translation stays in the view plane")
	controls.captured = true
	blocked := initial
	blocked.auto_yaw_speed = 0
	ecs.update_orbit_camera_3d(&blocked, &controls, 1.0 / 60.0)
	assert(blocked.target == initial.target, "UI-captured input cannot pan")
	controls.captured = false
	disabled := initial
	disabled.pan_action = ""
	ecs.update_orbit_camera_3d(&disabled, &controls, 0)
	assert(disabled.target == initial.target, "empty pan action preserves existing camera behavior")

	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry))
	defer ecs.destroy_registry(&registry)
	layers := make(map[string]u8); defer delete(layers)
	layers["Gameplay"] = 1
	world, ok := scene.load_with_layers("examples/skeletal_animation_3d/scenes/main.scene.json", &registry, layers)
	defer scene.clear_load_error()
	assert(ok, scene.last_load_error())
	defer ecs.destroy(&world)
	entity, found := ecs.find_entity_by_id(&world, "camera")
	assert(found)
	configured, _ := ecs.get_orbit_camera_3d(&world, entity)
	assert(configured.pan_action == "pan_camera" && configured.pan_x_axis == "pan_x" && configured.pan_y_axis == "pan_y")
	borrowed, _ := strings.clone("custom_pan")
	configured.pan_action, configured.pan_x_axis, configured.pan_y_axis = borrowed, borrowed, borrowed
	assert(ecs.set_orbit_camera_3d(&world, entity, configured))
	(transmute([]u8)borrowed)[0] = 'X'
	delete(borrowed)
	retained, _ := ecs.get_orbit_camera_3d(&world, entity)
	assert(retained.pan_action == "custom_pan" && retained.pan_x_axis == "custom_pan" && retained.pan_y_axis == "custom_pan")
	snapshot, serialized := ecs.runtime_component_json(&world, entity, "OrbitCamera3D")
	assert(serialized)
	roundtrip, parsed := ecs.orbit_camera_3d_from_json(snapshot)
	assert(parsed && roundtrip.pan_action == retained.pan_action && roundtrip.pan_sensitivity == retained.pan_sensitivity)
	invalid: json.Value
	assert(json.unmarshal(transmute([]u8)string(`{"pan_sensitivity":-1}`), &invalid, allocator = context.temp_allocator) == nil)
	_, valid := ecs.orbit_camera_3d_from_json(invalid)
	assert(!valid)
}
