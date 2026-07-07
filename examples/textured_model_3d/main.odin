package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

scene_view := r3d_bridge.Scene3D_Settings{
	grid_slices = 20,
	grid_spacing = 1,
	background_color = {8, 10, 14, 255},
}
world: ecs.World
bridge: r3d_bridge.Context
crate: ecs.Entity
material_view: Material_View

Material_View :: enum i32 {
	Final,
	Albedo,
	Normal,
	Roughness,
	Occlusion,
	Height,
	Metallic,
}

Material_View_Count :: 7

on_update :: proc(game: ^rune.Engine) {
	if rune.reload_scene_if_changed(game, &world, "examples/textured_model_3d/scenes/main.scene.json") {
		crate, _ = ecs.find_entity_by_id(&world, "crate")
		apply_material_view()
	}
	if rl.IsKeyPressed(.TAB) {
		material_view = Material_View((i32(material_view) + 1) % Material_View_Count)
		apply_material_view()
	}
	rune.update_orbit_cameras_3d(game, &world)
	transform, found := ecs.get_transform(&world, crate)
	if !found { return }
	transform.rotation[1] += 8 * game.delta_time
	ecs.set_transform(&world, crate, transform)
}

on_draw :: proc(game: ^rune.Engine) {
	if !r3d_bridge.draw_scene_ex(&bridge, &world, rune.asset_manager(game), scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rune.draw_gizmos(game, &world)
	rl.DrawText("Rune Textured Model 3D", 24, 24, 28, rl.RAYWHITE)
	rl.DrawText("Left mouse: orbit camera   Mouse wheel: zoom   Tab: material view", 24, 60, 18, rl.LIGHTGRAY)
	rl.DrawText("Material view:", 24, 94, 18, rl.RAYWHITE)
	rl.DrawText(material_view_name(material_view), 150, 94, 18, rl.RAYWHITE)
	rl.DrawFPS(24, 128)
}

apply_material_view :: proc() {
	renderer, found := ecs.get_model_renderer(&world, crate)
	if !found { return }
	renderer.material = material_view_path(material_view)
	ecs.set_model_renderer(&world, crate, renderer)
}

material_view_path :: proc(view: Material_View) -> string {
	switch view {
	case .Final: return "assets/materials/crate.material.json"
	case .Albedo: return "assets/materials/crate_albedo_debug.material.json"
	case .Normal: return "assets/materials/crate_normal_debug.material.json"
	case .Roughness: return "assets/materials/crate_roughness_debug.material.json"
	case .Occlusion: return "assets/materials/crate_ao_debug.material.json"
	case .Height: return "assets/materials/crate_height_debug.material.json"
	case .Metallic: return "assets/materials/crate_metallic_debug.material.json"
	}
	return "assets/materials/crate.material.json"
}

material_view_name :: proc(view: Material_View) -> cstring {
	switch view {
	case .Final: return "Final"
	case .Albedo: return "Albedo"
	case .Normal: return "Normal"
	case .Roughness: return "Roughness"
	case .Occlusion: return "AO"
	case .Height: return "Height"
	case .Metallic: return "Metallic"
	}
	return "Final"
}

main :: proc() {
	game, ok := rune.init("examples/textured_model_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/textured_model_3d/project.json")
		return
	}
	defer rune.shutdown(&game)

	bridge_ok: bool
	bridge, bridge_ok = r3d_bridge.init("examples/textured_model_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
	if !bridge_ok {
		fmt.eprintln("Could not initialize r3d")
		return
	}
	defer r3d_bridge.shutdown(&bridge)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/textured_model_3d/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the textured model scene")
		return
	}
	crate, _ = ecs.find_entity_by_id(&world, "crate")
	if crate == ecs.Entity(0) {
		fmt.eprintln("Scene is missing entity ID: crate")
		return
	}
	apply_material_view()
	rune.run(&game, on_update, on_draw)
}
