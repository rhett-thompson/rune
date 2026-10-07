package main

import "core:encoding/json"
import "rune:ecs"
import "rune:scene"

validate_camera_projection :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, loaded := scene.load("examples/camera_switching/scenes/main.scene.json", &registry)
	assert(loaded)
	defer ecs.destroy(&world)
	wide, wide_found := ecs.find_entity_by_id(&world, "wide_camera")
	side, side_found := ecs.find_entity_by_id(&world, "side_camera")
	assert(wide_found && side_found)
	wide_view, _ := ecs.get_camera_3d(&world, wide)
	side_view, _ := ecs.get_camera_3d(&world, side)
	assert(wide_view.projection == .perspective, "existing scenes default to perspective")
	zero_view: ecs.Camera3D
	assert(zero_view.projection == .perspective)
	assert(side_view.projection == .orthographic && side_view.fovy == 6)
	assert(ecs.set_active_camera_3d(&world, side))
	_, active_view, active_found := ecs.active_camera_3d(&world)
	assert(active_found && active_view.projection == .orthographic)

	snapshot, serialized := ecs.runtime_component_json(&world, side, "Camera3D")
	assert(serialized)
	assert(snapshot.(json.Object)["projection"].(json.String) == "orthographic")
	roundtrip, parsed := ecs.camera_3d_from_json(snapshot)
	assert(parsed && roundtrip == active_view, "runtime snapshots must round-trip projection and view size")
	assert(ecs.add_component(&world, &registry, wide, "Camera3D", snapshot))

	replacement: json.Value = json.String("perspective")
	assert(ecs.set_runtime_field(&world, &registry, side, "Camera3D", "projection", replacement))
	side_view, _ = ecs.get_camera_3d(&world, side)
	assert(side_view.projection == .perspective)
	side_view.projection = .orthographic
	assert(ecs.set_camera_3d(&world, side, side_view))
	for invalid in ([]json.Value{json.String("invalid"), json.Integer(1), json.Boolean(true), json.Null{}}) {
		assert(!ecs.set_runtime_field(&world, &registry, side, "Camera3D", "projection", invalid))
		retained, _ := ecs.get_camera_3d(&world, side)
		assert(retained == side_view, "invalid edits must preserve the camera")
	}
}
