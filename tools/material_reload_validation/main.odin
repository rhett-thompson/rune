package main

import "core:fmt"
import "core:os"
import "rune:assets"
import bridge "rune:r3d_bridge"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

ROOT :: "build/material-reload-validation"
SHADER :: `#pragma usage opaque
void fragment() { ALBEDO = vec3(0.8,0.2,0.1); }`
CHANGED_SHADER :: `#pragma usage opaque
void fragment() { ALBEDO = vec3(0.1,0.8,0.2); }`

write_image :: proc(path: cstring,color: rl.Color) {
	image:=rl.GenImageColor(8,8,color);defer rl.UnloadImage(image)
	assert(rl.ExportImage(image,path))
}
pixel :: proc(texture: rl.Texture2D) -> rl.Color {
	assert(texture.id!=0)
	image:=rl.LoadImageFromTexture(texture);assert(image.data!=nil);defer rl.UnloadImage(image)
	return rl.GetImageColor(image,4,4)
}

main :: proc() {
	runtime:=false
	for arg in os.args[1:] {if arg=="--runtime" {runtime=true} else {fmt.eprintln("Usage: material_reload_validation [--runtime]");os.exit(2)}}
	if !runtime {fmt.println("Material reload GPU checks skipped; use --runtime with a working display");return}
	assert(os.make_directory(ROOT)==nil || os.is_dir(ROOT))
	rl.SetTraceLogLevel(.WARNING);rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(128,128,"Selective material reload validation");defer rl.CloseWindow()
	gl.load_up_to(3,3,proc(p:rawptr,name:cstring) {(^rawptr)(p)^=rlgl.GetProcAddress(name)})
	manager:=assets.init(ROOT);defer assets.shutdown(&manager)
	ctx,ok:=bridge.init(ROOT,128,128);assert(ok);defer bridge.shutdown(&ctx)
	write_image(ROOT+"/a.png",{220,50,40,255})
	write_image(ROOT+"/b.png",{40,140,220,255})
	write_image(ROOT+"/channel.png",{128,128,128,255})
	assert(os.write_entire_file(ROOT+"/b.glsl",SHADER)==nil)
	assert(os.write_entire_file(ROOT+"/a.material.json",`{"texture":"a.png","filter":"point","mipmaps":false,"roughness":0.6}`)==nil)
	assert(os.write_entire_file(ROOT+"/b.material.json",`{"surface_shader":"b.glsl","texture":"b.png","roughness_texture":"channel.png","filter":"point","mipmaps":false,"roughness":0.4}`)==nil)
	bridge.material_from_path(&ctx,&manager,"a.material.json",{255,255,255,255})
	b:=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	before:=ctx.r3d_materials["b.material.json"]
	assert(before.owns_shader && before.orm_manager==&manager)
	sentinel:rl.Color={211,17,199,255}
	sentinel_image:=rl.GenImageColor(8,8,sentinel);defer rl.UnloadImage(sentinel_image)
	rl.UpdateTexture(b.albedo.texture,sentinel_image.data)
	assert(pixel(b.albedo.texture)==sentinel)
	hashes:=ctx.frame_stats.material_hashes
	a_data,loaded:=assets.material_data(&manager,"a.material.json");assert(loaded)
	preview:=a_data;preview.roughness=0.1
	assert(assets.set_material_preview(&manager,"a.material.json",preview))
	b=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	after:=ctx.r3d_materials["b.material.json"]
	assert(after.signature==before.signature && after.dependency_fingerprint==before.dependency_fingerprint)
	assert(ctx.frame_stats.material_hashes==hashes && b.shader==before.material.shader && pixel(b.albedo.texture)==sentinel,
		"unrelated preview keeps B's texture object, compiled shader, and fast cache hit")
	assert(b.orm.texture.id==before.material.orm.texture.id && !manager.generated_orm_states[before.orm_key].retired,
		"unrelated material edits preserve the borrowed generated ORM handle")
	assert(assets.clear_material_preview(&manager,"a.material.json"))
	assert(os.write_entire_file(ROOT+"/a.material.json",`{"texture":"a.png","filter":"point","mipmaps":false,"roughness":0.9}`)==nil)
	stale_a:=manager.materials["a.material.json"];stale_a.modified_time=-2;manager.materials["a.material.json"]=stale_a
	assets.refresh_materials(&manager)
	b=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	assert(ctx.frame_stats.material_hashes==hashes && b.shader==before.material.shader && pixel(b.albedo.texture)==sentinel,
		"an unrelated JSON reload also keeps B's GPU resources")
	write_image(ROOT+"/a.png",{120,60,40,255})
	manager.material_texture_watches["a.png"]=-2;assets.refresh_materials(&manager)
	b=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	assert(ctx.frame_stats.material_hashes==hashes && pixel(b.albedo.texture)==sentinel,
		"an unrelated watched image edit keeps B's resources")
	write_image(ROOT+"/b.png",{80,220,30,255})
	manager.material_texture_watches["b.png"]=-2
	assets.refresh_materials(&manager)
	b=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	updated_color:=pixel(b.albedo.texture)
	assert(updated_color!=sentinel && updated_color.g>updated_color.r,"B's own image edit reloads despite unchanged authored values")
	shader:=b.shader
	assert(os.write_entire_file(ROOT+"/b.glsl",CHANGED_SHADER)==nil)
	manager.material_texture_watches["b.glsl"]=-2;assets.refresh_materials(&manager)
	b=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	assert(b.shader!=nil && b.shader!=shader,"B's own shader edit recompiles its shader")
	shader=b.shader
	assert(os.write_entire_file(ROOT+"/b.glsl","invalid GLSL")==nil)
	manager.material_texture_watches["b.glsl"]=-2;assets.refresh_materials(&manager)
	b=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	assert(b.shader==shader && pixel(b.albedo.texture)==updated_color,"failed shader edits retain B's complete working material")
	assert(os.write_entire_file(ROOT+"/b.glsl",SHADER)==nil)
	manager.material_texture_watches["b.glsl"]=-2;assets.refresh_materials(&manager)
	b=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	data,data_ok:=assets.material_data(&manager,"b.material.json");assert(data_ok)
	old_orm,key,leased:=assets.lease_material_orm_texture(&manager,data,"held-result");assert(leased)
	old_pixel:=pixel(old_orm)
	write_image(ROOT+"/channel.png",{220,220,220,255})
	manager.material_texture_watches["channel.png"]=-2;assets.refresh_materials(&manager)
	assert(manager.generated_orm_states[key].retired && pixel(old_orm)==old_pixel,
		"an in-flight material lease keeps a retired source texture alive")
	b=bridge.material_from_path(&ctx,&manager,"b.material.json",{255,255,255,255})
	assert(pixel(b.orm.texture).g==220 && pixel(old_orm)==old_pixel)
	assets.release_material_orm_texture(&manager,key)
	_,old_present:=manager.generated_orm_states[key];assert(!old_present,"last lease release reclaims the retired texture")
	variant:=data;variant.surface_shader="";variant.wrap="repeat"
	first:=bridge.material_from_data(&ctx,&manager,"variant",variant)
	gl.BindTexture(gl.TEXTURE_2D,first.albedo.texture.id)
	wrap:i32;gl.GetTexParameteriv(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,&wrap);assert(wrap==gl.REPEAT)
	variant.wrap="clamp"
	second:=bridge.material_from_data(&ctx,&manager,"variant",variant)
	gl.BindTexture(gl.TEXTURE_2D,second.albedo.texture.id);gl.GetTexParameteriv(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,&wrap)
	assert(wrap==gl.CLAMP_TO_EDGE,"one path remains sensitive to distinct sampler variants")
	gl.BindTexture(gl.TEXTURE_2D,0)
	entries:=len(manager.generated_orm_states)
	for index in 0..<8 {
		variant.roughness=f32(index)/10
		bridge.material_from_data(&ctx,&manager,"variant",variant)
		assert(len(manager.generated_orm_states)<=entries,"replaced editor variants release their unused ORM leases")
	}
	fmt.println("Selective material GPU validation passed: unrelated preview cache reuse, own image/shader reload and failed-shader retention, sampler variants, ORM lease retirement and bounded replacement")
}
