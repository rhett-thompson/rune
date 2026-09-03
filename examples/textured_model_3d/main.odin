package main

import "core:fmt"
import "core:os"
import rune "rune:core"
import "rune:ecs"
import "rune:r3d_bridge"
import rl "vendor:raylib"

scene_view := r3d_bridge.Scene3D_Settings{
	grid_slices = 0,
	grid_spacing = 1,
	background_color = {8, 10, 14, 255},
}
bridge: r3d_bridge.Context
crate: ecs.Entity
material_view: Material_View
capture_mode: bool
capture_frame: int

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

initialize_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		bridge_ok: bool
		bridge, bridge_ok = r3d_bridge.init("examples/textured_model_3d", rl.GetScreenWidth(), rl.GetScreenHeight())
		if !bridge_ok { fmt.eprintln("Could not initialize r3d") }
	}
	crate, _ = ecs.find_entity_by_id(world, "crate")
	apply_material_view(world)
}

shutdown_scene :: proc(game: ^rune.Engine, world: ^ecs.World) {
	r3d_bridge.shutdown(&bridge)
}

on_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if rl.IsKeyPressed(.TAB) {
		material_view = Material_View((i32(material_view) + 1) % Material_View_Count)
		apply_material_view(world)
	}
	transform, found := ecs.get_transform(world, crate)
	if !found { return }
	transform.rotation[1] += 8 * game.delta_time
	ecs.set_transform(world, crate, transform)
}

on_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rl.DrawText("Rune Textured Model 3D", 24, 24, 28, rl.RAYWHITE)
	rl.DrawText("Left mouse: orbit camera   Mouse wheel: zoom   Tab: material view", 24, 60, 18, rl.LIGHTGRAY)
	rl.DrawText("Material view:", 24, 94, 18, rl.RAYWHITE)
	rl.DrawText(material_view_name(material_view), 150, 94, 18, rl.RAYWHITE)
	rl.DrawFPS(24, 128)
	if capture_mode && capture_frame == 30 {
		rl.TakeScreenshot("build/textured_model_3d_capture.png")
	}
	capture_frame += 1
	if capture_mode && capture_frame > 32 {
		rl.CloseWindow()
	}
}

apply_material_view :: proc(world: ^ecs.World) {
	renderer, found := ecs.get_model_renderer(world, crate)
	if !found { return }
	renderer.material = material_view_path(material_view)
	ecs.set_model_renderer(world, crate, renderer)
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
	capture_mode = len(os.args) > 1 && os.args[1] == "--capture"
	game, ok := rune.init("examples/textured_model_3d/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/textured_model_3d/project.json")
		return
	}
	defer rune.shutdown(&game)

	if !rune.register_system(&game, {
		name = "textured_model_3d",
		start = initialize_scene,
		update = on_update,
		draw = on_draw,
		on_scene_reloaded = initialize_scene,
		shutdown = shutdown_scene,
	}) {
		fmt.eprintln("Could not register textured-model system")
		return
	}
	if !rune.run(&game) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
