package r3d_bridge

import "core:fmt"
import "rune:assets"
import "rune:terrain"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Three maps occupy aligned square cells in a 1x4 atlas. The shader wraps
// samples inside each cell and caps mip levels before the cells merge.
// One atlas per layer fits R3D's four-custom-sampler budget.
Terrain_Layer_Asset :: struct {
	texture: rl.Texture2D,
	signature, revision: u64,
	color, pbr, sampling: [4]f32,
}

terrain_layer :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, path, source, field: string, base: r3d.Material) -> (Terrain_Layer_Asset, bool) {
	layer := r3d.GetDefaultMaterial()
	filter := "anisotropic_8x"
	mipmaps := true
	signature: u64
	if terrain.blend_layer_is_material(path) {
		data, ok := assets.material_data(manager, path)
		if !ok {
			assets.report_failure(manager, {kind=.Material, operation=.Load, source_path=source, field=field, asset_path=path, detail="could not load terrain layer material; using the base terrain material"})
			return {}, false
		}
		layer = material_from_data(ctx, manager, path, data)
		// The material bridge reports missing/broken file maps. Keep the last
		// complete terrain atlas until those files can be loaded again.
		has_orm := data.orm_texture!="" || data.ao_texture!="" || data.roughness_texture!="" || data.metallic_texture!=""
		if (data.texture!="" && layer.albedo.texture.id==0) ||
		   (data.normal!="" && layer.normal.texture.id==0) || (has_orm && layer.orm.texture.id==0) {
			if cached,found := ctx.terrain_layers[path]; found {return cached,true}
			return {},false
		}
		filter, mipmaps = data.filter, data.mipmaps
		signature = assets.material_data_signature(data)
	} else {
		texture, ok := assets.material_texture(manager, path, filter, mipmaps, source, field)
		if !ok {return {}, false}
		layer.albedo.texture = texture
		// Plain images retain the base material's scalar surface response.
		layer.orm.roughness, layer.orm.metalness, layer.orm.specular = base.orm.roughness, base.orm.metalness, base.orm.specular
		signature = assets.hash_value(0, manager.textures[path].modified_time)
	}
	revision := assets.material_asset_revision(manager)
	if cached, found := ctx.terrain_layers[path]; found && cached.signature == signature && cached.revision == revision {
		result := cached
		if !terrain.blend_layer_is_material(path) {
			result.pbr[1],result.pbr[2],result.color[3] = base.orm.roughness,base.orm.metalness,base.orm.specular
		}
		return result, true
	}
	texture, ok := terrain_layer_atlas(layer, mipmaps)
	if !ok {
		assets.report_failure(manager, {kind=.Texture, operation=.Load, source_path=source, field=field, asset_path=path, detail="could not create terrain layer maps; using the base terrain material"})
		if cached,found := ctx.terrain_layers[path]; found {return cached,true}
		return {}, false
	}
	mode: f32 = 2
	if filter == "point" {mode = 0} else if filter == "bilinear" || !mipmaps {mode = 1}
	if filter == "point" && mipmaps {mode = 3}
	anisotropy: f32 = 1
	if mipmaps {
		if filter == "anisotropic_4x" {anisotropy=4}
		if filter == "anisotropic_8x" {anisotropy=8}
		if filter == "anisotropic_16x" {anisotropy=16}
	}
	color := r3d.ColorSrgbToLinearVector3(layer.albedo.color)
	result := Terrain_Layer_Asset{texture=texture, signature=signature, revision=revision,
		color={color.x,color.y,color.z,layer.orm.specular},
		pbr={layer.orm.occlusion,layer.orm.roughness,layer.orm.metalness,layer.normal.scale},
		sampling={mode,f32(texture.width),f32(texture.mipmaps-1) if mipmaps else 0,anisotropy}}
	if old, found := ctx.terrain_layers[path]; found {rl.UnloadTexture(old.texture)}
	ctx.terrain_layers[retain_path(ctx,path)] = result
	assets.resolve_asset_failure(manager,source,field,path)
	return result, true
}

terrain_layer_atlas :: proc(material: r3d.Material, mipmaps: bool) -> (rl.Texture2D, bool) {
	images: [3]rl.Image
	defer {for image in images {if image.data != nil {rl.UnloadImage(image)}}}
	size: i32 = 8
	for texture, i in ([3]rl.Texture2D{material.albedo.texture,material.normal.texture,material.orm.texture}) {
		if texture.id == 0 {
			images[i] = rl.GenImageColor(1,1,rl.Color{128,128,255,255} if i == 1 else rl.WHITE)
		} else {images[i] = rl.LoadImageFromTexture(texture)}
		if images[i].data == nil {return {}, false}
		size = max(size,max(images[i].width,images[i].height))
	}
	// Bound GPU memory and fit the minimum supported 4096px texture dimension.
	size = min(size,1024)
	power: i32 = 8
	for power < size {power *= 2}
	size = power
	atlas := rl.GenImageColor(size,4*size,rl.WHITE)
	defer rl.UnloadImage(atlas)
	for &image, i in images {
		// Preserve the texels of lower-resolution maps inside a material.
		rl.ImageResizeNN(&image,size,size)
		rl.ImageDraw(&atlas,image,{0,0,f32(size),f32(size)},{0,f32(i)*f32(size),f32(size),f32(size)},rl.WHITE)
	}
	texture := rl.LoadTextureFromImage(atlas)
	if !rl.IsTextureValid(texture) {return {}, false}
	if mipmaps {rl.GenTextureMipmaps(&texture)}
	return texture, true
}

bind_terrain_material_layers :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, shader: ^r3d.SurfaceShader, blend: terrain.Blend, base: r3d.Material, source: string) -> bool {
	layers: [3]Terrain_Layer_Asset
	fields := [3]string{"grass","dirt","rock"}
	for path, i in ([3]string{blend.grass,blend.dirt,blend.rock}) {
		ok: bool
		layers[i],ok = terrain_layer(ctx,manager,path,source,fmt.tprintf("blend.%s",fields[i]),base)
		if !ok {return false}
	}
	for &layer, i in layers {
		r3d.SetSurfaceShaderSampler(shader,fmt.ctprintf("u_%s",fields[i]),layer.texture)
		r3d.SetSurfaceShaderUniform(shader,fmt.ctprintf("u_%s_color",fields[i]),&layer.color)
		r3d.SetSurfaceShaderUniform(shader,fmt.ctprintf("u_%s_pbr",fields[i]),&layer.pbr)
		r3d.SetSurfaceShaderUniform(shader,fmt.ctprintf("u_%s_sampling",fields[i]),&layer.sampling)
	}
	return true
}
