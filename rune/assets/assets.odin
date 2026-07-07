package assets

import "core:encoding/json"
import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:strings"
import "core:time"
import "rune:jsonutil"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

Texture_Asset :: struct {
	texture:       rl.Texture2D,
	modified_time: i64,
}

Model_Asset :: struct {
	model:         rl.Model,
	modified_time: i64,
}

Font_Asset :: struct {
	font:          rl.Font,
	modified_time: i64,
}

Material_Data :: struct {
	base_color:      [4]u8,
	texture:         string,
	normal:          string,
	orm_texture:     string,
	roughness_texture: string,
	metallic_texture: string,
	ao_texture:      string,
	height_texture:  string,
	filter:          string,
	mipmaps:         bool,
	lod_bias:        f32,
	lighting:        bool,
	roughness:       f32,
	metallic:        f32,
	height_scale:    f32,
}

Material_Asset :: struct {
	data:          Material_Data,
	modified_time: i64,
}

// Asset paths are the first asset identifiers. Stable IDs can be layered on later.
Asset_Manager :: struct {
	root:             string,
	textures:         map[string]Texture_Asset,
	models:           map[string]Model_Asset,
	fonts:            map[string]Font_Asset,
	materials:        map[string]Material_Asset,
	generated_orm_textures: map[string]Texture_Asset,
	missing_textures: map[string]bool,
	missing_texture:  rl.Texture2D,
}

// init must run after raylib creates a window because it creates the small
// checkerboard texture returned when an asset cannot be loaded.
init :: proc(root: string) -> Asset_Manager {
	missing_image := rl.GenImageColor(2, 2, rl.MAGENTA)
	defer rl.UnloadImage(missing_image)
	return Asset_Manager{
		root = root,
		textures = make(map[string]Texture_Asset),
		models = make(map[string]Model_Asset),
		fonts = make(map[string]Font_Asset),
		materials = make(map[string]Material_Asset),
		generated_orm_textures = make(map[string]Texture_Asset),
		missing_textures = make(map[string]bool),
		missing_texture = rl.LoadTextureFromImage(missing_image),
	}
}

font :: proc(manager: ^Asset_Manager, path: string) -> (rl.Font, bool) {
	if len(path) == 0 { return {}, false }
	if asset, found := manager.fonts[path]; found { return asset.font, true }
	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	loaded := rl.LoadFont(path_cstring)
	if !rl.IsFontValid(loaded) { return {}, false }
	manager.fonts[path] = Font_Asset{font = loaded, modified_time = modified_time(full_path)}
	return loaded, true
}

// model returns a cached model loaded from a project-relative path.
model :: proc(manager: ^Asset_Manager, path: string) -> (rl.Model, bool) {
	if len(path) == 0 { return {}, false }
	if asset, found := manager.models[path]; found { return asset.model, true }
	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	loaded := rl.LoadModel(path_cstring)
	if !rl.IsModelValid(loaded) { return {}, false }
	ensure_model_tangents(&loaded)
	manager.models[path] = Model_Asset{model = loaded, modified_time = modified_time(full_path)}
	return loaded, true
}

// material returns a cached material JSON definition. r3d owns the shader
// pipeline, so Rune materials are pure data.
material :: proc(manager: ^Asset_Manager, path: string) -> (Material_Data, bool) {
	return material_data(manager, path)
}

material_data :: proc(manager: ^Asset_Manager, path: string) -> (Material_Data, bool) {
	if len(path) == 0 { return {}, false }
	if asset, found := manager.materials[path]; found {
		return asset.data, true
	}
	full_path := resolve_path(manager, path)
	data, loaded := load_material_data(full_path)
	if !loaded { return {}, false }
	manager.materials[path] = Material_Asset{
		data = data,
		modified_time = modified_time(full_path),
	}
	return data, true
}

// texture returns a cached texture for a project-relative asset path. Missing
// files return the shared fallback, and are remembered so they are not loaded
// from disk every frame.
texture :: proc(manager: ^Asset_Manager, path: string) -> (rl.Texture2D, bool) {
	if len(path) == 0 {
		return manager.missing_texture, false
	}
	if asset, found := manager.textures[path]; found {
		return asset.texture, true
	}
	if manager.missing_textures[path] {
		return manager.missing_texture, false
	}

	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	loaded := rl.LoadTexture(path_cstring)
	if !rl.IsTextureValid(loaded) {
		manager.missing_textures[path] = true
		return manager.missing_texture, false
	}
	manager.textures[path] = Texture_Asset{texture = loaded, modified_time = modified_time(full_path)}
	return loaded, true
}

configure_texture :: proc(texture: ^rl.Texture2D, filter: string, mipmaps: bool) {
	if mipmaps && texture.mipmaps <= 1 {
		rl.GenTextureMipmaps(texture)
	}
	apply_texture_filter(texture^, filter, mipmaps)
}

material_texture :: proc(manager: ^Asset_Manager, path, filter: string, mipmaps: bool) -> (rl.Texture2D, bool) {
	loaded_texture, loaded := texture(manager, path)
	if !loaded { return loaded_texture, false }
	asset := manager.textures[path]
	if mipmaps && asset.texture.mipmaps <= 1 {
		rl.GenTextureMipmaps(&asset.texture)
		manager.textures[path] = asset
	}
	apply_texture_filter(asset.texture, filter, mipmaps)
	return asset.texture, true
}

material_orm_texture :: proc(manager: ^Asset_Manager, data: Material_Data) -> (rl.Texture2D, bool) {
	if manager == nil { return {}, false }
	if len(data.orm_texture) > 0 {
		return material_texture(manager, data.orm_texture, data.filter, data.mipmaps)
	}
	if len(data.ao_texture) == 0 && len(data.roughness_texture) == 0 && len(data.metallic_texture) == 0 {
		return {}, false
	}
	key := generated_orm_key(manager, data)
	if asset, found := manager.generated_orm_textures[key]; found {
		return asset.texture, true
	}
	texture, loaded := generate_orm_texture(manager, data)
	if !loaded { return {}, false }
	manager.generated_orm_textures[key] = Texture_Asset{texture = texture}
	return texture, true
}

generated_orm_key :: proc(manager: ^Asset_Manager, data: Material_Data) -> string {
	return fmt.tprintf(
		"orm|ao=%s:%d|rough=%s:%d|metal=%s:%d|r=%f|m=%f|filter=%s|mips=%v",
		data.ao_texture,
		path_modified_time(manager, data.ao_texture),
		data.roughness_texture,
		path_modified_time(manager, data.roughness_texture),
		data.metallic_texture,
		path_modified_time(manager, data.metallic_texture),
		data.roughness,
		data.metallic,
		data.filter,
		data.mipmaps,
	)
}

generate_orm_texture :: proc(manager: ^Asset_Manager, data: Material_Data) -> (rl.Texture2D, bool) {
	ao_image, has_ao := load_material_image(manager, data.ao_texture)
	roughness_image, has_roughness := load_material_image(manager, data.roughness_texture)
	metallic_image, has_metallic := load_material_image(manager, data.metallic_texture)
	defer {
		if has_ao { rl.UnloadImage(ao_image) }
		if has_roughness { rl.UnloadImage(roughness_image) }
		if has_metallic { rl.UnloadImage(metallic_image) }
	}

	width, height, has_size := orm_texture_size(ao_image, has_ao, roughness_image, has_roughness, metallic_image, has_metallic)
	if !has_size {
		width = 1
		height = 1
	}
	if has_ao && (ao_image.width != width || ao_image.height != height) {
		rl.ImageResize(&ao_image, width, height)
	}
	if has_roughness && (roughness_image.width != width || roughness_image.height != height) {
		rl.ImageResize(&roughness_image, width, height)
	}
	if has_metallic && (metallic_image.width != width || metallic_image.height != height) {
		rl.ImageResize(&metallic_image, width, height)
	}
	default_ao := u8(255)
	default_roughness := scalar_to_channel(data.roughness)
	default_metallic := scalar_to_channel(data.metallic)
	pixel_count := int(width * height)
	orm_pixels := make([]rl.Color, pixel_count)
	defer delete(orm_pixels)

	for y in 0..<height {
		for x in 0..<width {
			index := int(y * width + x)
			ao := default_ao
			roughness := default_roughness
			metallic := default_metallic
			if has_ao { ao = red_channel_at(ao_image, index, default_ao) }
			if has_roughness { roughness = red_channel_at(roughness_image, index, default_roughness) }
			if has_metallic { metallic = red_channel_at(metallic_image, index, default_metallic) }
			orm_pixels[index] = rl.Color{ao, roughness, metallic, 255}
		}
	}

	orm_image := rl.Image{
		data = raw_data(orm_pixels),
		width = width,
		height = height,
		mipmaps = 1,
		format = .UNCOMPRESSED_R8G8B8A8,
	}
	texture := rl.LoadTextureFromImage(orm_image)
	if !rl.IsTextureValid(texture) { return {}, false }
	configure_texture(&texture, data.filter, data.mipmaps)
	return texture, true
}

load_material_image :: proc(manager: ^Asset_Manager, path: string) -> (rl.Image, bool) {
	if len(path) == 0 { return {}, false }
	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	defer delete(path_cstring)
	image := rl.LoadImage(path_cstring)
	if !rl.IsImageValid(image) { return {}, false }
	return image, true
}

orm_texture_size :: proc(ao_image: rl.Image, has_ao: bool, roughness_image: rl.Image, has_roughness: bool, metallic_image: rl.Image, has_metallic: bool) -> (c.int, c.int, bool) {
	if has_ao { return ao_image.width, ao_image.height, true }
	if has_roughness { return roughness_image.width, roughness_image.height, true }
	if has_metallic { return metallic_image.width, metallic_image.height, true }
	return 0, 0, false
}

red_channel_at :: proc(image: rl.Image, index: int, fallback: u8) -> u8 {
	if image.data == nil { return fallback }
	bytes := cast([^]u8)image.data
	#partial switch image.format {
	case .UNCOMPRESSED_GRAYSCALE:
		return bytes[index]
	case .UNCOMPRESSED_GRAY_ALPHA:
		return bytes[index * 2]
	case .UNCOMPRESSED_R8G8B8:
		return bytes[index * 3]
	case .UNCOMPRESSED_R8G8B8A8:
		return bytes[index * 4]
	case:
		return fallback
	}
}

scalar_to_channel :: proc(value: f32) -> u8 {
	if value <= 0 { return 0 }
	if value >= 1 { return 255 }
	return u8(value * 255 + 0.5)
}

// refresh reloads cached textures whose on-disk modified time changed. Invalid
// replacement files leave the currently working texture in place.
refresh :: proc(manager: ^Asset_Manager) {
	orm_sources_changed := false
	for path, asset in manager.textures {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time { continue }
		path_cstring, _ := strings.clone_to_cstring(full_path)
		replacement := rl.LoadTexture(path_cstring)
		if !rl.IsTextureValid(replacement) { continue }
		rl.UnloadTexture(asset.texture)
		updated_asset := asset
		updated_asset.texture = replacement
		updated_asset.modified_time = current_time
		manager.textures[path] = updated_asset
		orm_sources_changed = true
	}
	for path, asset in manager.fonts {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time { continue }
		path_cstring, _ := strings.clone_to_cstring(full_path)
		replacement := rl.LoadFont(path_cstring)
		if !rl.IsFontValid(replacement) { continue }
		rl.UnloadFont(asset.font)
		updated_asset := asset
		updated_asset.font = replacement
		updated_asset.modified_time = current_time
		manager.fonts[path] = updated_asset
	}
	if orm_sources_changed {
		clear_generated_orm_textures(manager)
	}
}

refresh_materials :: proc(manager: ^Asset_Manager) {
	materials_changed := false
	for path, asset in manager.materials {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time { continue }
		data, loaded := load_material_data(full_path)
		if !loaded { continue }
		manager.materials[path] = Material_Asset{
			data = data,
			modified_time = current_time,
		}
		materials_changed = true
	}
	if materials_changed {
		clear_generated_orm_textures(manager)
	}
}

refresh_models :: proc(manager: ^Asset_Manager) {
	for path, asset in manager.models {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time { continue }
		path_cstring, _ := strings.clone_to_cstring(full_path)
		replacement := rl.LoadModel(path_cstring)
		if !rl.IsModelValid(replacement) { continue }
		ensure_model_tangents(&replacement)
		rl.UnloadModel(asset.model)
		updated_asset := asset
		updated_asset.model = replacement
		updated_asset.modified_time = current_time
		manager.models[path] = updated_asset
	}
}

clear_generated_orm_textures :: proc(manager: ^Asset_Manager) {
	for _, asset in manager.generated_orm_textures {
		if rl.IsTextureValid(asset.texture) {
			rl.UnloadTexture(asset.texture)
		}
	}
	clear(&manager.generated_orm_textures)
}

resolve_path :: proc(manager: ^Asset_Manager, path: string) -> string {
	if filepath.is_abs(path) { return path }
	full_path, _ := filepath.join({manager.root, path})
	return full_path
}

ensure_model_tangents :: proc(model: ^rl.Model) {
	for mesh_index in 0..<model.meshCount {
		mesh := &model.meshes[mesh_index]
		if mesh.vertexCount <= 0 || mesh.texcoords == nil || mesh.normals == nil { continue }
		if mesh.tangents == nil {
			rl.GenMeshTangents(mesh)
		}
		if mesh.tangents != nil {
			upload_mesh_tangents(mesh)
		}
	}
}

upload_mesh_tangents :: proc(mesh: ^rl.Mesh) {
	if mesh.vaoId == 0 || mesh.vboId == nil || mesh.tangents == nil { return }
	tangent_attribute_index := c.uint(rl.ShaderLocationIndex.VERTEX_TANGENT)
	tangent_byte_count := c.int(int(mesh.vertexCount) * 4 * size_of(f32))
	if mesh.vboId[int(tangent_attribute_index)] != 0 {
		rlgl.UpdateVertexBuffer(mesh.vboId[int(tangent_attribute_index)], rawptr(mesh.tangents), tangent_byte_count, 0)
		return
	}
	if !rlgl.EnableVertexArray(mesh.vaoId) { return }
	mesh.vboId[int(tangent_attribute_index)] = rlgl.LoadVertexBuffer(rawptr(mesh.tangents), tangent_byte_count, false)
	rlgl.SetVertexAttribute(tangent_attribute_index, 4, rlgl.FLOAT, false, 0, 0)
	rlgl.EnableVertexAttribute(tangent_attribute_index)
	rlgl.DisableVertexArray()
}

load_material_data :: proc(full_path: string) -> (Material_Data, bool) {
	file_data, read_error := os.read_entire_file(full_path, context.allocator)
	if read_error != nil { return {}, false }
	value: json.Value
	if json.unmarshal(file_data, &value) != nil { return {}, false }
	object, ok := value.(json.Object)
	if !ok { return {}, false }
	result := Material_Data{base_color = {255, 255, 255, 255}}
	if value, found := object["base_color"]; found && !read_color(value, &result.base_color) { return {}, false }
	if value, found := object["texture"]; found {
		result.texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["albedo"]; found {
		result.texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["normal"]; found {
		result.normal, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["orm_texture"]; found {
		result.orm_texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["orm"]; found {
		result.orm_texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["roughness_texture"]; found {
		result.roughness_texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["metallic_texture"]; found {
		result.metallic_texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["ao_texture"]; found {
		result.ao_texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["occlusion"]; found {
		result.ao_texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["height_texture"]; found {
		result.height_texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["height"]; found {
		result.height_texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	result.filter = "anisotropic_8x"
	result.mipmaps = true
	if value, found := object["filter"]; found {
		result.filter, ok = value.(json.String)
		if !ok || !is_texture_filter_name(result.filter) { return {}, false }
	}
	if value, found := object["mipmaps"]; found {
		result.mipmaps, ok = value.(json.Boolean)
		if !ok { return {}, false }
	}
	if value, found := object["lod_bias"]; found {
		result.lod_bias, ok = jsonutil.number(value)
		if !ok || result.lod_bias < 0 || result.lod_bias > 4 { return {}, false }
	}
	if value, found := object["lighting"]; found {
		result.lighting, ok = value.(json.Boolean)
		if !ok { return {}, false }
	}
	result.roughness = 0.5
	result.metallic = 0
	result.height_scale = 0.03
	if value, found := object["roughness"]; found {
		result.roughness, ok = jsonutil.number(value)
		if !ok || result.roughness < 0 || result.roughness > 1 { return {}, false }
	}
	if value, found := object["metallic"]; found {
		result.metallic, ok = jsonutil.number(value)
		if !ok || result.metallic < 0 || result.metallic > 1 { return {}, false }
	}
	if value, found := object["height_scale"]; found {
		result.height_scale, ok = jsonutil.number(value)
		if !ok || result.height_scale < 0 || result.height_scale > 0.2 { return {}, false }
	}
	return result, true
}

read_color :: proc(data: json.Value, result: ^[4]u8) -> bool {
	array, ok := data.(json.Array)
	if !ok || len(array) != 4 { return false }
	for value, index in array {
		number, number_ok := jsonutil.number(value)
		if !number_ok || number < 0 || number > 255 || number != f32(i32(number)) { return false }
		result[index] = u8(number)
	}
	return true
}

is_texture_filter_name :: proc(name: string) -> bool {
	return name == "point" ||
	       name == "bilinear" ||
	       name == "trilinear" ||
	       name == "anisotropic_4x" ||
	       name == "anisotropic_8x" ||
	       name == "anisotropic_16x"
}

texture_filter_from_name :: proc(name: string) -> rl.TextureFilter {
	if name == "point" { return .POINT }
	if name == "bilinear" { return .BILINEAR }
	if name == "trilinear" { return .TRILINEAR }
	if name == "anisotropic_4x" { return .ANISOTROPIC_4X }
	if name == "anisotropic_8x" { return .ANISOTROPIC_8X }
	if name == "anisotropic_16x" { return .ANISOTROPIC_16X }
	return .ANISOTROPIC_8X
}

apply_texture_filter :: proc(texture: rl.Texture2D, filter: string, mipmaps: bool) {
	if is_anisotropic_filter_name(filter) {
		rl.SetTextureFilter(texture, .TRILINEAR if mipmaps else .BILINEAR)
		rl.SetTextureFilter(texture, texture_filter_from_name(filter))
		return
	}
	if filter == "trilinear" && !mipmaps {
		rl.SetTextureFilter(texture, .BILINEAR)
		return
	}
	rl.SetTextureFilter(texture, texture_filter_from_name(filter))
}

is_anisotropic_filter_name :: proc(name: string) -> bool {
	return name == "anisotropic_4x" ||
	       name == "anisotropic_8x" ||
	       name == "anisotropic_16x"
}

modified_time :: proc(path: string) -> i64 {
	modified, err := os.modification_time_by_path(path)
	if err != nil { return -1 }
	return time.to_unix_nanoseconds(modified)
}

path_modified_time :: proc(manager: ^Asset_Manager, path: string) -> i64 {
	if len(path) == 0 { return 0 }
	return modified_time(resolve_path(manager, path))
}

shutdown :: proc(manager: ^Asset_Manager) {
	clear_generated_orm_textures(manager)
	for _, asset in manager.textures {
		rl.UnloadTexture(asset.texture)
	}
	for _, asset in manager.models {
		rl.UnloadModel(asset.model)
	}
	for _, asset in manager.fonts {
		rl.UnloadFont(asset.font)
	}
	if rl.IsTextureValid(manager.missing_texture) {
		rl.UnloadTexture(manager.missing_texture)
	}
	delete(manager.generated_orm_textures)
}
