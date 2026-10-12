package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import "rune:validation"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

MATERIAL_PATH :: "material-shader-validation.material.json"
SHADER_PATH :: "material-shader-validation.glsl"
MATERIAL :: `{"surface_shader":"material-shader-validation.glsl","surface_shader_time":true,"lighting":false}`
SHADER :: `#pragma usage opaque
uniform float u_time;
void fragment() {
    ALBEDO = mix(vec3(0.8,0.05,0.02),vec3(0.02,0.05,0.8),clamp(u_time,0.0,1.0));
}`

main :: proc() {
	full_path :: "build/" + MATERIAL_PATH
	shader_path :: "build/" + SHADER_PATH
	defer os.remove(full_path)
	defer os.remove(shader_path)
	assert(os.write_entire_file(full_path, MATERIAL) == nil)
	assert(os.write_entire_file(shader_path, SHADER) == nil)
	data, ok := assets.load_material_data(full_path)
	assert(ok && data.surface_shader == SHADER_PATH && data.surface_shader_time)
	defer assets.destroy_material_data(&data)
	owned := assets.clone_material_data(data)
	defer assets.destroy_material_data(&owned)
	assert(owned.surface_shader == data.surface_shader)
	bytes := transmute([]u8)owned.surface_shader
	bytes[0] = 'X'
	assert(data.surface_shader == SHADER_PATH, "shader paths must be independently owned")
	assert(assets.material_data_signature(owned) != assets.material_data_signature(data))
	copy := data
	copy.surface_shader_time = false
	assert(assets.material_data_signature(copy) != assets.material_data_signature(data))
	for invalid in ([]string{`{"surface_shader":true}`, `{"surface_shader":""}`, `{"surface_shader_time":1}`}) {
		assert(os.write_entire_file(full_path, invalid) == nil)
		_, accepted := assets.load_material_data(full_path)
		assert(!accepted, invalid)
	}
	assert(os.write_entire_file(full_path, MATERIAL) == nil)
	report := validation.init_report()
	defer validation.destroy_report(&report)
	validation.validate_material(&report, full_path, "build")
	assert(validation.is_valid(&report))
	assert(os.remove(shader_path) == nil)
	validation.validate_material(&report, full_path, "build")
	assert(!validation.is_valid(&report), "missing shader references must be reported")
	assert(os.write_entire_file(shader_path, SHADER) == nil)
	for arg in os.args[1:] {if arg == "--runtime" {validate_runtime()}}
	fmt.println("Material shader parsing, ownership, signature and validation passed")
}

sample :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager, time: f32) -> rl.Color {
	for _ in 0 ..< 3 {
		rl.BeginDrawing()
		assert(bridge.draw_scene_ex(ctx, world, manager, {background_color=rl.BLACK, material_time=time, material_time_override=true}))
		rl.EndDrawing()
	}
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)
	return rl.GetImageColor(image, 160, 120)
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320, 240, "Material shader validation")
	defer rl.CloseWindow()
	manager := assets.init("build")
	defer assets.shutdown(&manager)
	ctx, ok := bridge.init("build", 320, 240)
	assert(ok)
	defer bridge.shutdown(&ctx)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world := ecs.init()
	defer ecs.destroy(&world)
	camera := ecs.create_entity(&world)
	assert(ecs.add(&world, &registry, camera, ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&world, &registry, camera, ecs.Camera3D{active=true, target={0,0,-1}, up={0,1,0}, fovy=60}))
	box := ecs.create_entity(&world)
	assert(ecs.add(&world, &registry, box, ecs.Transform{position={0,0,-4}, scale={2,2,2}}))
	assert(ecs.add(&world, &registry, box, ecs.MeshRenderer{primitive="cube", material=MATERIAL_PATH, color={255,255,255,255}, shadows=false}))
	red := sample(&ctx, &world, &manager, 0)
	shader := ctx.r3d_materials[MATERIAL_PATH].material.shader
	assert(shader != nil && ctx.r3d_materials[MATERIAL_PATH].owns_shader)
	assert(red.r > red.b*2, "the initial frame must receive explicit time zero")
	blue := sample(&ctx, &world, &manager, 1)
	assert(blue.b > blue.r*2, "a changed material clock must update actual shader output")
	assert(ctx.r3d_materials[MATERIAL_PATH].material.shader == shader, "time updates reuse the compiled shader")
	assert(sample(&ctx, &world, &manager, 1) == blue, "fixed material time is repeatable")
	assert(os.write_entire_file("build/"+SHADER_PATH, "this is not GLSL") == nil)
	manager.material_texture_watches[SHADER_PATH] = -2
	assets.refresh_materials(&manager)
	assert(sample(&ctx, &world, &manager, 1) == blue, "invalid shader reload keeps the previous material")
	assert(ctx.r3d_materials[MATERIAL_PATH].material.shader == shader)
	assert(os.write_entire_file("build/"+SHADER_PATH, SHADER) == nil)
	manager.material_texture_watches[SHADER_PATH] = -2
	assets.refresh_materials(&manager)
	assert(sample(&ctx, &world, &manager, 0) == red)
	assert(ctx.r3d_materials[MATERIAL_PATH].material.shader != shader, "source edits reload the shader")
	assert(os.write_entire_file("build/"+MATERIAL_PATH, `{"lighting":false,"base_color":[20,220,20,255]}`) == nil)
	stale := manager.materials[MATERIAL_PATH]
	stale.modified_time = -2
	manager.materials[MATERIAL_PATH] = stale
	assets.refresh_materials(&manager)
	green := sample(&ctx, &world, &manager, 0)
	assert(green.g > green.r*2 && green.g > green.b*2)
	assert(!ctx.r3d_materials[MATERIAL_PATH].owns_shader && ctx.r3d_materials[MATERIAL_PATH].material.shader == nil)
	fmt.println("Material shader GPU clock, cache, reload retention, recovery and release passed")
}
