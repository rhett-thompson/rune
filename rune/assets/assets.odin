package assets

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "rune:jsonutil"
import rl "vendor:raylib"

Texture_Asset :: struct {
	texture:       rl.Texture2D,
	modified_time: i64,
}

Model_Asset :: struct {
	modified_time: i64,
	revision:      u64,
}

Font_Asset :: struct {
	font:          rl.Font,
	modified_time: i64,
}

Material_Data :: struct {
	base_color:        [4]u8,
	texture:           string,
	normal:            string,
	emission:          string,
	orm_texture:       string,
	roughness_texture: string,
	metallic_texture:  string,
	ao_texture:        string,
	height_texture:    string,
	filter:            string,
	mipmaps:           bool,
	lod_bias:          f32,
	lighting:          bool,
	emission_color:    [4]u8,
	emission_energy:   f32,
	normal_scale:      f32,
	ao_strength:       f32,
	roughness:         f32,
	metallic:          f32,
	specular:          f32,
	alpha_cutoff:      f32,
	transparency:      string,
	blend:             string,
	cull:              string,
	height_scale:      f32,
}

Material_Asset :: struct {
	data:          Material_Data,
	modified_time: i64,
}

// Asset paths are the first asset identifiers. Stable IDs can be layered on later.
Asset_Manager :: struct {
	root:                     string,
	textures:                 map[string]Texture_Asset,
	models:                   map[string]Model_Asset,
	fonts:                    map[string]Font_Asset,
	materials:                map[string]Material_Asset,
	generated_orm_textures:   map[string]Texture_Asset,
	material_texture_watches: map[string]i64,
	material_revision:        u64,
	missing_textures:         map[string]bool,
	missing_texture:          rl.Texture2D,
}

// init must run after raylib creates a window because it creates the small
// checkerboard texture returned when an asset cannot be loaded.
init :: proc(root: string) -> Asset_Manager {
	missing_image := rl.GenImageColor(2, 2, rl.MAGENTA)
	defer rl.UnloadImage(missing_image)
	return Asset_Manager {
		root = root,
		textures = make(map[string]Texture_Asset),
		models = make(map[string]Model_Asset),
		fonts = make(map[string]Font_Asset),
		materials = make(map[string]Material_Asset),
		generated_orm_textures = make(map[string]Texture_Asset),
		material_texture_watches = make(map[string]i64),
		material_revision = 1,
		missing_textures = make(map[string]bool),
		missing_texture = rl.LoadTextureFromImage(missing_image),
	}
}

font :: proc(manager: ^Asset_Manager, path: string) -> (rl.Font, bool) {
	if len(path) == 0 {return {}, false}
	if asset, found := manager.fonts[path]; found {return asset.font, true}
	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	loaded := rl.LoadFont(path_cstring)
	if !rl.IsFontValid(loaded) {return {}, false}
	manager.fonts[path] = Font_Asset {
		font          = loaded,
		modified_time = modified_time(full_path),
	}
	return loaded, true
}

// model_revision registers a project-relative model for timestamp polling and
// returns the generation consumed by renderer-specific model caches.
model_revision :: proc(manager: ^Asset_Manager, path: string) -> (u64, bool) {
	if manager == nil || len(path) == 0 {return 0, false}
	if asset, found := manager.models[path]; found {return asset.revision, true}
	full_path := resolve_path(manager, path)
	current_time := modified_time(full_path)
	if current_time < 0 {return 0, false}
	manager.models[path] = Model_Asset {
		modified_time = current_time,
		revision      = 1,
	}
	return 1, true
}

// material returns a cached material JSON definition. r3d owns the shader
// pipeline, so Rune materials are pure data.
material :: proc(manager: ^Asset_Manager, path: string) -> (Material_Data, bool) {
	return material_data(manager, path)
}

material_data :: proc(manager: ^Asset_Manager, path: string) -> (Material_Data, bool) {
	if len(path) == 0 {return {}, false}
	if asset, found := manager.materials[path]; found {
		return asset.data, true
	}
	full_path := resolve_path(manager, path)
	data, loaded := load_material_data(full_path)
	if !loaded {return {}, false}
	manager.materials[path] = Material_Asset {
		data          = data,
		modified_time = modified_time(full_path),
	}
	watch_material_textures(manager, data)
	return data, true
}

material_asset_revision :: proc(manager: ^Asset_Manager) -> u64 {
	if manager == nil {return 0}
	return manager.material_revision
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
	manager.textures[path] = Texture_Asset {
		texture       = loaded,
		modified_time = modified_time(full_path),
	}
	return loaded, true
}

configure_texture :: proc(texture: ^rl.Texture2D, filter: string, mipmaps: bool) {
	if mipmaps && texture.mipmaps <= 1 {
		rl.GenTextureMipmaps(texture)
	}
	apply_texture_filter(texture^, filter, mipmaps)
}

material_texture :: proc(
	manager: ^Asset_Manager,
	path, filter: string,
	mipmaps: bool,
) -> (
	rl.Texture2D,
	bool,
) {
	loaded_texture, loaded := texture(manager, path)
	if !loaded {return loaded_texture, false}
	asset := manager.textures[path]
	if mipmaps && asset.texture.mipmaps <= 1 {
		rl.GenTextureMipmaps(&asset.texture)
		manager.textures[path] = asset
	}
	apply_texture_filter(asset.texture, filter, mipmaps)
	return asset.texture, true
}

material_orm_texture :: proc(
	manager: ^Asset_Manager,
	data: Material_Data,
) -> (
	rl.Texture2D,
	bool,
) {
	if manager == nil {return {}, false}
	if len(data.orm_texture) > 0 {
		return material_texture(manager, data.orm_texture, data.filter, data.mipmaps)
	}
	if len(data.ao_texture) == 0 &&
	   len(data.roughness_texture) == 0 &&
	   len(data.metallic_texture) == 0 {
		return {}, false
	}
	key := generated_orm_key(manager, data)
	if asset, found := manager.generated_orm_textures[key]; found {
		return asset.texture, true
	}
	texture, loaded := generate_orm_texture(manager, data)
	if !loaded {return {}, false}
	manager.generated_orm_textures[key] = Texture_Asset {
		texture = texture,
	}
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

generate_orm_texture :: proc(
	manager: ^Asset_Manager,
	data: Material_Data,
) -> (
	rl.Texture2D,
	bool,
) {
	ao_image, has_ao := load_material_image(manager, data.ao_texture)
	roughness_image, has_roughness := load_material_image(manager, data.roughness_texture)
	metallic_image, has_metallic := load_material_image(manager, data.metallic_texture)
	defer {
		if has_ao {rl.UnloadImage(ao_image)}
		if has_roughness {rl.UnloadImage(roughness_image)}
		if has_metallic {rl.UnloadImage(metallic_image)}
	}

	width, height, has_size := orm_texture_size(
		ao_image,
		has_ao,
		roughness_image,
		has_roughness,
		metallic_image,
		has_metallic,
	)
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
	default_roughness := u8(255)
	default_metallic := u8(255)
	pixel_count := int(width * height)
	orm_pixels := make([]rl.Color, pixel_count)
	defer delete(orm_pixels)

	for y in 0 ..< height {
		for x in 0 ..< width {
			index := int(y * width + x)
			ao := default_ao
			roughness := default_roughness
			metallic := default_metallic
			if has_ao {ao = red_channel_at(ao_image, index, default_ao)}
			if has_roughness {roughness = red_channel_at(roughness_image, index, default_roughness)}
			if has_metallic {metallic = red_channel_at(metallic_image, index, default_metallic)}
			orm_pixels[index] = rl.Color{ao, roughness, metallic, 255}
		}
	}

	orm_image := rl.Image {
		data    = raw_data(orm_pixels),
		width   = width,
		height  = height,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	texture := rl.LoadTextureFromImage(orm_image)
	if !rl.IsTextureValid(texture) {return {}, false}
	configure_texture(&texture, data.filter, data.mipmaps)
	return texture, true
}

load_material_image :: proc(manager: ^Asset_Manager, path: string) -> (rl.Image, bool) {
	if len(path) == 0 {return {}, false}
	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	defer delete(path_cstring)
	image := rl.LoadImage(path_cstring)
	if !rl.IsImageValid(image) {return {}, false}
	return image, true
}

orm_texture_size :: proc(
	ao_image: rl.Image,
	has_ao: bool,
	roughness_image: rl.Image,
	has_roughness: bool,
	metallic_image: rl.Image,
	has_metallic: bool,
) -> (
	c.int,
	c.int,
	bool,
) {
	if has_ao {return ao_image.width, ao_image.height, true}
	if has_roughness {return roughness_image.width, roughness_image.height, true}
	if has_metallic {return metallic_image.width, metallic_image.height, true}
	return 0, 0, false
}

red_channel_at :: proc(image: rl.Image, index: int, fallback: u8) -> u8 {
	if image.data == nil {return fallback}
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
	if value <= 0 {return 0}
	if value >= 1 {return 255}
	return u8(value * 255 + 0.5)
}

// refresh reloads cached textures whose on-disk modified time changed. Invalid
// replacement files leave the currently working texture in place.
refresh :: proc(manager: ^Asset_Manager) {
	orm_sources_changed := false
	for path, asset in manager.textures {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time {continue}
		path_cstring, _ := strings.clone_to_cstring(full_path)
		replacement := rl.LoadTexture(path_cstring)
		if !rl.IsTextureValid(replacement) {continue}
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
		if current_time == asset.modified_time {continue}
		path_cstring, _ := strings.clone_to_cstring(full_path)
		replacement := rl.LoadFont(path_cstring)
		if !rl.IsFontValid(replacement) {continue}
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
		if current_time == asset.modified_time {continue}
		data, loaded := load_material_data(full_path)
		if !loaded {continue}
		manager.materials[path] = Material_Asset {
			data          = data,
			modified_time = current_time,
		}
		watch_material_textures(manager, data)
		materials_changed = true
	}
	for path, previous_time in manager.material_texture_watches {
		current_time := modified_time(resolve_path(manager, path))
		if current_time == previous_time {continue}
		manager.material_texture_watches[path] = current_time
		materials_changed = true
	}
	if materials_changed {
		clear_generated_orm_textures(manager)
		manager.material_revision += 1
		if manager.material_revision == 0 {manager.material_revision = 1}
	}
}

refresh_models :: proc(manager: ^Asset_Manager) {
	for path, asset in manager.models {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time {continue}
		updated_asset := asset
		updated_asset.modified_time = current_time
		updated_asset.revision += 1
		if updated_asset.revision == 0 {updated_asset.revision = 1}
		manager.models[path] = updated_asset
	}
}

watch_material_textures :: proc(manager: ^Asset_Manager, data: Material_Data) {
	paths := [8]string {
		data.texture,
		data.normal,
		data.emission,
		data.orm_texture,
		data.roughness_texture,
		data.metallic_texture,
		data.ao_texture,
		data.height_texture,
	}
	for path in paths {
		if len(path) == 0 {continue}
		if _, watched := manager.material_texture_watches[path]; watched {continue}
		manager.material_texture_watches[path] = modified_time(resolve_path(manager, path))
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
	if filepath.is_abs(path) {return path}
	full_path, _ := filepath.join({manager.root, path})
	return full_path
}

load_material_data :: proc(full_path: string) -> (Material_Data, bool) {
	file_data, read_error := os.read_entire_file(full_path, context.allocator)
	if read_error != nil {return {}, false}
	value: json.Value
	if json.unmarshal(file_data, &value) != nil {return {}, false}
	object, ok := value.(json.Object)
	if !ok {return {}, false}
	result := Material_Data {
		base_color = {255, 255, 255, 255},
	}
	if value, found := object["base_color"];
	   found && !read_color(value, &result.base_color) {return {}, false}
	if value, found := object["texture"]; found {
		result.texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["albedo"]; found {
		result.texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["normal"]; found {
		result.normal, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["emission"]; found {
		result.emission, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["emission_texture"]; found {
		result.emission, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["orm_texture"]; found {
		result.orm_texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["orm"]; found {
		result.orm_texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["roughness_texture"]; found {
		result.roughness_texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["metallic_texture"]; found {
		result.metallic_texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["ao_texture"]; found {
		result.ao_texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["occlusion"]; found {
		result.ao_texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["height_texture"]; found {
		result.height_texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	if value, found := object["height"]; found {
		result.height_texture, ok = value.(json.String)
		if !ok {return {}, false}
	}
	result.filter = "anisotropic_8x"
	result.mipmaps = true
	if value, found := object["filter"]; found {
		result.filter, ok = value.(json.String)
		if !ok || !is_texture_filter_name(result.filter) {return {}, false}
	}
	if value, found := object["mipmaps"]; found {
		result.mipmaps, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	if value, found := object["lod_bias"]; found {
		result.lod_bias, ok = jsonutil.number(value)
		if !ok || result.lod_bias < 0 || result.lod_bias > 4 {return {}, false}
	}
	if value, found := object["lighting"]; found {
		result.lighting, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	result.emission_color = {255, 255, 255, 255}
	if value, found := object["emission_color"];
	   found && !read_color(value, &result.emission_color) {return {}, false}
	result.emission_energy = 0
	if value, found := object["emission_energy"]; found {
		result.emission_energy, ok = jsonutil.number(value)
		if !ok || result.emission_energy < 0 {return {}, false}
	}
	result.normal_scale = 1
	if value, found := object["normal_scale"]; found {
		result.normal_scale, ok = jsonutil.number(value)
		if !ok || result.normal_scale < 0 || result.normal_scale > 4 {return {}, false}
	}
	result.ao_strength = 1
	if value, found := object["ao_strength"]; found {
		result.ao_strength, ok = jsonutil.number(value)
		if !ok || result.ao_strength < 0 || result.ao_strength > 1 {return {}, false}
	}
	result.roughness = 0.5
	result.metallic = 0
	result.specular = 0.5
	result.alpha_cutoff = 0.01
	if value, found := object["alpha_cutoff"]; found {
		result.alpha_cutoff, ok = jsonutil.number(value)
		if !ok || result.alpha_cutoff < 0 || result.alpha_cutoff > 1 {return {}, false}
	}
	result.transparency = "disabled"
	if value, found := object["transparency"]; found {
		result.transparency, ok = value.(json.String)
		if !ok || !is_transparency_mode_name(result.transparency) {return {}, false}
	}
	result.blend = "mix"
	if value, found := object["blend"]; found {
		result.blend, ok = value.(json.String)
		if !ok || !is_blend_mode_name(result.blend) {return {}, false}
	}
	result.cull = "back"
	if value, found := object["cull"]; found {
		result.cull, ok = value.(json.String)
		if !ok || !is_cull_mode_name(result.cull) {return {}, false}
	}
	result.height_scale = 0.03
	if value, found := object["roughness"]; found {
		result.roughness, ok = jsonutil.number(value)
		if !ok || result.roughness < 0 || result.roughness > 1 {return {}, false}
	}
	if value, found := object["metallic"]; found {
		result.metallic, ok = jsonutil.number(value)
		if !ok || result.metallic < 0 || result.metallic > 1 {return {}, false}
	}
	if value, found := object["specular"]; found {
		result.specular, ok = jsonutil.number(value)
		if !ok || result.specular < 0 || result.specular > 1 {return {}, false}
	}
	if value, found := object["height_scale"]; found {
		result.height_scale, ok = jsonutil.number(value)
		if !ok || result.height_scale < 0 || result.height_scale > 0.2 {return {}, false}
	}
	return result, true
}

read_color :: proc(data: json.Value, result: ^[4]u8) -> bool {
	array, ok := data.(json.Array)
	if !ok || len(array) != 4 {return false}
	for value, index in array {
		number, number_ok := jsonutil.number(value)
		if !number_ok || number < 0 || number > 255 || number != f32(i32(number)) {return false}
		result[index] = u8(number)
	}
	return true
}

is_texture_filter_name :: proc(name: string) -> bool {
	return(
		name == "point" ||
		name == "bilinear" ||
		name == "trilinear" ||
		name == "anisotropic_4x" ||
		name == "anisotropic_8x" ||
		name == "anisotropic_16x" \
	)
}

texture_filter_from_name :: proc(name: string) -> rl.TextureFilter {
	if name == "point" {return .POINT}
	if name == "bilinear" {return .BILINEAR}
	if name == "trilinear" {return .TRILINEAR}
	if name == "anisotropic_4x" {return .ANISOTROPIC_4X}
	if name == "anisotropic_8x" {return .ANISOTROPIC_8X}
	if name == "anisotropic_16x" {return .ANISOTROPIC_16X}
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
	return name == "anisotropic_4x" || name == "anisotropic_8x" || name == "anisotropic_16x"
}

is_transparency_mode_name :: proc(name: string) -> bool {
	return name == "disabled" || name == "prepass" || name == "alpha"
}

is_blend_mode_name :: proc(name: string) -> bool {
	return(
		name == "mix" ||
		name == "additive" ||
		name == "multiply" ||
		name == "premultiplied_alpha" \
	)
}

is_cull_mode_name :: proc(name: string) -> bool {
	return name == "back" || name == "front" || name == "none"
}

modified_time :: proc(path: string) -> i64 {
	modified, err := os.modification_time_by_path(path)
	if err != nil {return -1}
	return time.to_unix_nanoseconds(modified)
}

path_modified_time :: proc(manager: ^Asset_Manager, path: string) -> i64 {
	if len(path) == 0 {return 0}
	return modified_time(resolve_path(manager, path))
}

shutdown :: proc(manager: ^Asset_Manager) {
	clear_generated_orm_textures(manager)
	for _, asset in manager.textures {
		rl.UnloadTexture(asset.texture)
	}
	for _, asset in manager.fonts {
		rl.UnloadFont(asset.font)
	}
	if rl.IsTextureValid(manager.missing_texture) {
		rl.UnloadTexture(manager.missing_texture)
	}
	delete(manager.generated_orm_textures)
	delete(manager.textures)
	delete(manager.models)
	delete(manager.fonts)
	delete(manager.materials)
	delete(manager.material_texture_watches)
	delete(manager.missing_textures)
}
