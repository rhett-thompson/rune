package r3d_bridge

import "rune:assets"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Generated textures belong to the existing per-path material cache. Replacing
// a material or shutting the bridge down releases them with other owned maps.
apply_procedural_material :: proc(material: ^r3d.Material, asset: ^R3D_Material_Asset, data: assets.Material_Data, prepared:^Material_Reload_Request=nil) -> bool {
	albedo := len(data.texture) == 0
	normal := len(data.normal) == 0 && data.procedural.bump_strength > 0
	orm := len(data.orm_texture) == 0 && len(data.ao_texture) == 0 &&
		len(data.roughness_texture) == 0 && len(data.metallic_texture) == 0 && data.procedural.roughness_variation > 0
	if !albedo && !normal && !orm {return true}
	images:assets.Procedural_Material_Images
	if prepared!=nil {images=prepared.procedural} else {
		ok:bool
		images,ok=assets.generate_procedural_material_images(data.procedural)
		if !ok {return false}
	}
	defer if prepared==nil {assets.destroy_procedural_material_images(&images)}
	valid:=true
	if albedo {
		if texture, ok := procedural_texture(images.albedo, data, true); ok {
			material.albedo.texture = texture
			asset.owns_albedo = true
		} else {valid=false}
	}
	if normal {
		if texture, ok := procedural_texture(images.normal, data, false); ok {
			material.normal.texture = texture
			asset.owns_normal = true
		} else {valid=false}
	}
	if orm {
		if texture, ok := procedural_texture(images.orm, data, false); ok {
			material.orm.texture = texture
			material.orm.occlusion = data.ao_strength
			asset.owns_orm = true
		} else {valid=false}
	}
	return valid
}

procedural_texture :: proc(image: rl.Image, data: assets.Material_Data, is_color: bool) -> (rl.Texture2D, bool) {
	texture: rl.Texture2D
	if is_color {
		// The pinned R3D image upload consumes its CPU image, including after
		// sRGB reformatting. Transfer an independent copy; keep our source owned.
		owned:=rl.ImageCopy(image)
		if owned.data==nil {return {},false}
		texture = r3d.LoadTextureFromImage(owned,true)
	} else {
		texture = rl.LoadTextureFromImage(image)
	}
	if !rl.IsTextureValid(texture) {return {}, false}
	rl.SetTextureWrap(texture, .REPEAT)
	assets.configure_texture(&texture, data.filter, data.mipmaps, data.wrap)
	return texture, true
}
