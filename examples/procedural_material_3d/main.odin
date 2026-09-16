package main

import "core:fmt"
import "core:os"
import example_text "../shared/text"
import rune "rune:core"
import "rune:assets"
import "rune:ecs"
import "rune:input"
import "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

bridge: r3d_bridge.Context
selected: int
PRESET_COUNT :: 9
paths := [PRESET_COUNT]string{
	"assets/stone.material.json", "assets/moss.material.json", "assets/metal.material.json",
	"assets/grass.material.json", "assets/granite.material.json", "assets/wood.material.json",
	"assets/sand.material.json", "assets/terracotta.material.json", "assets/snow.material.json",
}
names := [PRESET_COUNT]cstring{"STONE", "MOSS", "HAMMERED METAL", "GRASS", "GRANITE", "WOOD", "SAND", "TERRACOTTA", "SNOW"}
preset_actions := [PRESET_COUNT]string{"stone", "moss", "metal", "grass", "granite", "wood", "sand", "terracotta", "snow"}
smoke: bool
frames: int
filtered_aa: r3d.AntiAliasingMode
Sampling_Backup :: struct {
	active: bool,
	filter: string,
	mipmaps: bool,
	modified_time: i64,
}
sampling_backups: [PRESET_COUNT]Sampling_Backup

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if !bridge.initialized {
		ok: bool
		bridge, ok = r3d_bridge.init("examples/procedural_material_3d", rl.GetRenderWidth(), rl.GetRenderHeight())
		if !ok {fmt.eprintln("Could not initialize r3d")}
		filtered_aa = r3d.GetAntiAliasingMode()
	}
	select_material(world)
}

select_material :: proc(world: ^ecs.World) {
	for id in ([]string{"sphere", "cube", "tile"}) {
		entity, found := ecs.find_entity_by_id(world, id)
		if !found {continue}
		if mesh, found := ecs.get(world, entity, ecs.MeshRenderer); found {
			mesh.material = paths[selected]
			ecs.set(world, entity, mesh)
		}
		if sphere, found := ecs.get(world, entity, ecs.SphereRenderer); found {
			sphere.material = paths[selected]
			ecs.set(world, entity, sphere)
		}
	}
}

update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	controls := rune.input_state(game)
	previous := selected
	for action, index in preset_actions {if input.pressed(controls, action) {selected = index}}
	if previous != selected {select_material(world)}
	manager := rune.asset_manager(game)
	data, loaded := assets.material_data(manager, paths[selected])
	if !loaded {return}
	if input.pressed(controls, "filter") {
		toggle_retro(manager, selected)
		data, _ = assets.material_data(manager, paths[selected])
	}
	resolution_step := 0
	if input.pressed(controls, "resolution_down") {resolution_step -= 1}
	if input.pressed(controls, "resolution_up") {resolution_step += 1}
	if resolution_step != 0 {
		adjust_resolution(manager, selected, resolution_step)
		data, _ = assets.material_data(manager, paths[selected])
	}
	p := data.procedural
	filter, mipmaps := data.filter, data.mipmaps
	if input.pressed(controls, "seed") {p.seed = (p.seed + 1) % 65536}
	if input.pressed(controls, "scale_up") {p.scale = min(64, p.scale + 1)}
	if input.pressed(controls, "scale_down") {p.scale = max(1, p.scale - 1)}
	if input.pressed(controls, "detail") {p.octaves = p.octaves % 6 + 1}
	if input.pressed(controls, "contrast_up") {p.contrast = min(8, p.contrast + 0.1)}
	if input.pressed(controls, "contrast_down") {p.contrast = max(0.1, p.contrast - 0.1)}
	if input.pressed(controls, "bump") {p.bump_strength = 0 if p.bump_strength > 0 else 0.08}
	if input.pressed(controls, "reset") {
		full_path := assets.resolve_path(manager, paths[selected])
		original, ok := assets.load_material_data(full_path)
		if ok {
			clear_sampling_backup(selected)
			apply_tweaks(manager, paths[selected], original.procedural, original.filter, original.mipmaps)
			assets.destroy_material_data(&original)
			return
		}
	}
	apply_tweaks(manager, paths[selected], p, filter, mipmaps)
}

clear_sampling_backup :: proc(index: int) {
	delete(sampling_backups[index].filter)
	sampling_backups[index] = {}
}

adjust_resolution :: proc(manager: ^assets.Asset_Manager, index, step: int) {
	cached, found := manager.materials[paths[index]]
	if !found {return}
	p := cached.data.procedural
	p.resolution = max(8, p.resolution / 2) if step < 0 else min(1024, p.resolution * 2)
	apply_tweaks(manager, paths[index], p, cached.data.filter, cached.data.mipmaps)
}

toggle_retro :: proc(manager: ^assets.Asset_Manager, index: int) {
	cached, found := manager.materials[paths[index]]
	if !found {return}
	if sampling_backups[index].active && sampling_backups[index].modified_time != cached.modified_time {
		// A material reload replaces the saved preview settings as well.
		clear_sampling_backup(index)
	}
	p := cached.data.procedural
	if cached.data.filter == "point" && !cached.data.mipmaps {
		backup := sampling_backups[index]
		if backup.active {
			apply_tweaks(manager, paths[index], p, backup.filter, backup.mipmaps)
		} else {
			apply_tweaks(manager, paths[index], p, "anisotropic_8x", true)
		}
		clear_sampling_backup(index)
	} else {
		clear_sampling_backup(index)
		sampling_backups[index] = {active = true,
			filter = assets.clone_asset_string(cached.data.filter), mipmaps = cached.data.mipmaps,
			modified_time = cached.modified_time}
		apply_tweaks(manager, paths[index], p, "point", false)
	}
}

apply_tweaks :: proc(manager: ^assets.Asset_Manager, path: string, p: assets.Procedural_Material, filter: string, mipmaps: bool) {
	cached, found := manager.materials[path]
	if !found {return}
	if cached.data.procedural == p && cached.data.filter == filter && cached.data.mipmaps == mipmaps {return}
	if cached.data.filter != filter {
		// Material strings remain owned by the asset manager, including live edits.
		owned := assets.clone_asset_string(filter)
		delete(cached.data.filter)
		cached.data.filter = owned
	}
	cached.data.procedural = p
	cached.data.mipmaps = mipmaps
	manager.materials[path] = cached
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	data, loaded := assets.material_data(rune.asset_manager(game), paths[selected])
	if !loaded {return}
	retro := data.filter == "point" && !data.mipmaps
	r3d.SetAntiAliasingMode(.NONE if retro else filtered_aa)
	// The scene profile reapplies AA during draw_scene_ex. Override its preview
	// value too, then restore the authored profile for the next draw/reload.
	post, _ := ecs.find_entity_by_id(world, "post")
	profile, has_profile := ecs.get(world, post, ecs.PostProcessing)
	if retro && has_profile {
		preview := profile
		preview.anti_aliasing = .disabled
		ecs.set(world, post, preview)
	}
	r3d_bridge.draw_scene_ex(&bridge, world, rune.asset_manager(game), {background_color = {16,21,29,255}})
	if retro && has_profile {ecs.set(world, post, profile)}
	p := data.procedural
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), 158, {12,17,25,245})
	example_text.draw("PROCEDURAL MATERIALS", 28, 20, 28, {231,235,240,255})
	example_text.draw(fmt.ctprintf("%s   /   Seed %d   Scale %d   Detail %d   Contrast %.1f   Bump %s   %dpx / %s",
		names[selected], p.seed, p.scale, p.octaves, p.contrast, "ON" if p.bump_strength > 0 else "OFF",
		p.resolution, "RETRO" if retro else "FILTERED"),
		28, 60, 18, {144,206,182,255})
	example_text.draw("1 Stone   2 Moss   3 Metal   4 Grass   5 Granite   6 Wood   7 Sand   8 Terracotta   9 Snow",
		28, 96, 16, {177,190,206,255})
	example_text.draw("N Seed    UP / DOWN Scale    D Detail    LEFT / RIGHT Contrast    B Bump    Q / E Resolution    F Retro    R Reset",
		28, 126, 16, {177,190,206,255})
	example_text.draw("Drag to orbit. Edit the selected material JSON and save to reload. Key tweaks are temporary.",
		28, rl.GetScreenHeight()-36, 17, {205,214,224,255})
	frames += 1
	if smoke && frames % 8 == 4 {
		rlgl.DrawRenderBatchActive()
		rl.TakeScreenshot(fmt.ctprintf("build/procedural-preset-%d-filtered.png", selected + 1))
		toggle_retro(rune.asset_manager(game), selected)
		unchanged, _ := assets.material_data(rune.asset_manager(game), paths[selected])
		assert(unchanged.procedural.resolution == p.resolution)
		for _ in 0 ..< 8 {adjust_resolution(rune.asset_manager(game), selected, -1)}
	}
	if smoke && frames % 8 == 0 {
		rlgl.DrawRenderBatchActive()
		rl.TakeScreenshot(fmt.ctprintf("build/procedural-preset-%d-retro.png", selected + 1))
		assert(retro && p.resolution == 8 && r3d.GetAntiAliasingMode() == .NONE)
		backup := sampling_backups[selected]
		toggle_retro(rune.asset_manager(game), selected)
		restored, _ := assets.material_data(rune.asset_manager(game), paths[selected])
		assert(restored.procedural.resolution == p.resolution && restored.mipmaps == backup.mipmaps)
		if selected == PRESET_COUNT - 1 {rune.request_exit(game)} else {selected += 1; select_material(world)}
	}
}

shutdown :: proc(game: ^rune.Engine, world: ^ecs.World) {
	for index in 0 ..< len(sampling_backups) {clear_sampling_backup(index)}
	r3d_bridge.shutdown(&bridge)
}

main :: proc() {
	for arg in os.args[1:] {if arg == "--smoke" {smoke = true; rl.SetConfigFlags({.WINDOW_HIDDEN})}}
	game, ok := rune.init("examples/procedural_material_3d/project.json")
	if !ok {fmt.eprintln("Could not load procedural material project"); return}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) {return}
	if !rune.register_system(&game, {name = "procedural_materials", start = start, on_scene_reloaded = start,
		update = update, draw = draw, shutdown = shutdown}) {return}
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error())}
}
