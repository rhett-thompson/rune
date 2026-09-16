package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "rune:assets"
import "rune:validation"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"
import gl "vendor:OpenGL"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}

main :: proc() {
	p, ok, _ := assets.procedural_material_from_json(parse(`{}`))
	assert(ok && p == assets.default_procedural_material())
	partial, valid, _ := assets.procedural_material_from_json(parse(`{"seed":17,"scale":12}`))
	assert(valid && partial.seed == 17 && partial.scale == 12 && partial.octaves == 4)
	wood, wood_ok, _ := assets.procedural_material_from_json(parse(`{"pattern":"wood"}`))
	assert(wood_ok && wood.pattern == .wood)
	assert(assets.procedural_material_signature(0, wood) != assets.procedural_material_signature(0, p))
	for bad in ([]string{`null`, `[]`, `true`, `{"typo":1}`, `{"enabled":1}`, `{"resolution":33}`,
		`{"pattern":"invalid"}`, `{"pattern":1}`,
		`{"resolution":4}`, `{"resolution":2048}`, `{"scale":0}`, `{"scale":1.5}`, `{"seed":-1}`, `{"seed":65536}`,
		`{"octaves":0}`, `{"octaves":7}`, `{"contrast":0}`, `{"contrast":1e99}`, `{"persistence":2}`,
		`{"bump_strength":-1}`, `{"roughness_variation":2}`, `{"color_a":[0,0,0]}`, `{"color_b":[256,0,0,255]}`}) {
		_, accepted, _ := assets.procedural_material_from_json(parse(bad))
		assert(!accepted, bad)
	}
	// Noise and its slope remain continuous across both UV tile boundaries.
	for index in 0 ..< 31 {
		v := f32(index) / 31
		a := assets.procedural_height(p, 0, v)
		b := assets.procedural_height(p, 1, v)
		assert(math.abs(a-b) < 0.00001)
		assert(math.abs(assets.procedural_height(p, v, 0)-assets.procedural_height(p, v, 1)) < 0.00001)
		assert(math.abs(assets.procedural_height(p, -0.00001, v)-assets.procedural_height(p, 0.00001, v)) < 0.001)
		assert(math.abs(assets.procedural_height(wood, 0, v)-assets.procedural_height(wood, 1, v)) < 0.0001)
		assert(math.abs(assets.procedural_height(wood, v, 0)-assets.procedural_height(wood, v, 1)) < 0.0001)
	}
	p.resolution = 32
	a, a_ok := assets.generate_procedural_material_images(p)
	assert(a_ok)
	defer assets.destroy_procedural_material_images(&a)
	b, b_ok := assets.generate_procedural_material_images(p)
	assert(b_ok)
	defer assets.destroy_procedural_material_images(&b)
	pa := ([^][4]u8)(a.albedo.data)[:1024]
	pb := ([^][4]u8)(b.albedo.data)[:1024]
	normals := ([^][4]u8)(a.normal.data)[:1024]
	for color, i in pa {
		assert(color == pb[i], "same seed must reproduce identical pixels")
		assert(color[3] == 255)
		n := normals[i]
		x, y, z := f32(n[0])/127.5-1, f32(n[1])/127.5-1, f32(n[2])/127.5-1
		assert(math.abs(x*x+y*y+z*z-1) < 0.02 && z > 0)
	}
	p.seed += 1
	c, c_ok := assets.generate_procedural_material_images(p)
	assert(c_ok)
	defer assets.destroy_procedural_material_images(&c)
	pc := ([^][4]u8)(c.albedo.data)[:1024]
	changed := 0
	for color, i in pa {if color != pc[i] {changed += 1}}
	assert(changed > 900, "a new seed changes the surface")
	p.bump_strength, p.roughness_variation = 0, 0
	p.color_a, p.color_b = {20,30,40,255}, {20,30,40,255}
	flat, flat_ok := assets.generate_procedural_material_images(p)
	assert(flat_ok)
	defer assets.destroy_procedural_material_images(&flat)
	for color in ([^][4]u8)(flat.albedo.data)[:1024] {assert(color == p.color_a)}
	for color in ([^][4]u8)(flat.normal.data)[:1024] {assert(color == [4]u8{128,128,255,255})}
	for color in ([^][4]u8)(flat.orm.data)[:1024] {assert(color == [4]u8{255,255,255,255})}
	p.contrast = math.nan_f32()
	_, invalid_ok := assets.generate_procedural_material_images(p)
	assert(!invalid_ok)
	validate_files()
	for arg in os.args[1:] {if arg == "--runtime" {validate_runtime()}}
	fmt.println("Procedural materials: parsing, tiling, deterministic maps, normals, validation, and signatures passed")
}

validate_files :: proc() {
	path :: "build/procedural-validation.material.json"
	defer os.remove(path)
	assert(os.write_entire_file(path, `{"lighting":true,"procedural":{"seed":42}}`) == nil)
	data, ok := assets.load_material_data(path)
	assert(ok && data.procedural.seed == 42 && data.normal_scale == 1)
	defer assets.destroy_material_data(&data)
	sig := assets.material_data_signature(data)
	copy := assets.clone_material_data(data)
	defer assets.destroy_material_data(&copy)
	assert(assets.material_data_signature(copy) == sig)
	copy.procedural.seed += 1
	assert(assets.material_data_signature(copy) != sig)
	assert(os.write_entire_file(path, `{"procedural":{"scale":0}}`) == nil)
	_, accepted := assets.load_material_data(path)
	assert(!accepted)
	report := validation.init_report()
	defer validation.destroy_report(&report)
	validation.validate_material(&report, path, "build")
	assert(!validation.is_valid(&report) && report.diagnostics[0].path == "$.procedural.scale")
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320, 240, "Procedural material validation")
	defer rl.CloseWindow()
	manager := assets.init("build")
	defer assets.shutdown(&manager)
	ctx, initialized := bridge.init("build", 320, 240)
	assert(initialized)
	defer bridge.shutdown(&ctx)
	path :: "procedural-runtime.material.json"
	full_path :: "build/procedural-runtime.material.json"
	defer os.remove(full_path)
	assert(os.write_entire_file(full_path, `{"lighting":true,"procedural":{"resolution":8}}`) == nil)
	data, loaded := assets.material_data(&manager, path)
	assert(loaded)
	first := bridge.material_from_data(&ctx, &manager, path, data)
	assert(rl.IsTextureValid(first.albedo.texture) && rl.IsTextureValid(first.normal.texture) && rl.IsTextureValid(first.orm.texture))
	assert(first.albedo.texture.width == 8 && first.normal.texture.width == 8 && first.orm.texture.width == 8)
	assert(ctx.r3d_materials[path].owns_albedo && ctx.r3d_materials[path].owns_normal && ctx.r3d_materials[path].owns_orm)
	second := bridge.material_from_data(&ctx, &manager, path, data)
	assert(first.albedo.texture.id == second.albedo.texture.id && len(ctx.r3d_materials) == 1)
	validate_retro_sampling(&ctx, &manager, data)
	// Failed reload retains the previous working definition and textures.
	assert(os.write_entire_file(full_path, `{"procedural":{"octaves":0}}`) == nil)
	stale := manager.materials[path]
	stale.modified_time = -2
	manager.materials[path] = stale
	assets.refresh_materials(&manager)
	retained, retained_ok := assets.material_data(&manager, path)
	assert(retained_ok && retained.procedural == data.procedural)
	// Valid reload replaces maps in the same cache entry.
	assert(os.write_entire_file(full_path, `{"lighting":true,"procedural":{"resolution":64,"seed":42}}`) == nil)
	stale = manager.materials[path]
	stale.modified_time = -2
	manager.materials[path] = stale
	assets.refresh_materials(&manager)
	reloaded, reload_ok := assets.material_data(&manager, path)
	assert(reload_ok && reloaded.procedural.seed == 42)
	third := bridge.material_from_data(&ctx, &manager, path, reloaded)
	assert(third.albedo.texture.width == 64 && len(ctx.r3d_materials) == 1)
	// Disabling removes ownership of all generated maps.
	reloaded.procedural.enabled = false
	bridge.material_from_data(&ctx, &manager, path, reloaded)
	assert(!ctx.r3d_materials[path].owns_albedo && !ctx.r3d_materials[path].owns_normal && !ctx.r3d_materials[path].owns_orm)
	// Explicit map channels override generation independently.
	image := rl.GenImageColor(8, 8, {120,140,160,255})
	defer rl.UnloadImage(image)
	assert(rl.ExportImage(image, "build/procedural-override.png"))
	defer os.remove("build/procedural-override.png")
	reloaded.procedural.enabled = true
	reloaded.texture = "procedural-override.png"
	override := bridge.material_from_data(&ctx, &manager, path, reloaded)
	assert(override.albedo.texture.width == 8 && override.normal.texture.width == 64 && override.orm.texture.width == 64)
	reloaded.normal = "procedural-override.png"
	reloaded.roughness_texture = "procedural-override.png"
	override = bridge.material_from_data(&ctx, &manager, path, reloaded)
	assert(override.normal.texture.width == 8 && override.orm.texture.width == 8)
	assert(!ctx.r3d_materials[path].owns_orm, "packed file channels are owned by the asset manager")
	for _ in 0 ..< 8 {
		reloaded.procedural.seed += 1
		bridge.material_from_data(&ctx, &manager, path, reloaded)
		assert(len(ctx.r3d_materials) == 1, "tweaks do not accumulate material entries")
	}
	fmt.println("Procedural material GPU cache, regeneration, failed reload retention, and disable passed")
}

validate_retro_sampling :: proc(ctx: ^bridge.Context, manager: ^assets.Asset_Manager, source: assets.Material_Data) {
	gl.load_up_to(3, 3, proc(p: rawptr, name: cstring) {(^rawptr)(p)^ = rlgl.GetProcAddress(name)})
	data := source
	data.procedural.resolution = 16
	data.filter, data.mipmaps = "point", false
	mat := bridge.material_from_data(ctx, manager, "retro-sampling", data)
	for texture in ([3]rl.Texture2D{mat.albedo.texture, mat.normal.texture, mat.orm.texture}) {
		assert(texture.width == 16 && texture.height == 16)
		gl.BindTexture(gl.TEXTURE_2D, texture.id)
		min_filter, mag_filter: i32
		gl.GetTexParameteriv(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, &min_filter)
		gl.GetTexParameteriv(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, &mag_filter)
		assert(min_filter == gl.NEAREST && mag_filter == gl.NEAREST, "retro maps must use nearest-neighbor GPU sampling")
		assert(texture.mipmaps == 1, "retro maps must not generate mipmaps")
	}
	gl.BindTexture(gl.TEXTURE_2D, 0)
	bridge.unload_owned_material_maps(ctx.r3d_materials["retro-sampling"])
	delete_key(&ctx.r3d_materials, "retro-sampling")
	fmt.println("Retro albedo, normal, and ORM GPU sampling passed")
}
