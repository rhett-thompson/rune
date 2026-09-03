package assets

import "core:c"
import "core:encoding/json"
import "core:hash"
import "core:os"
import "core:path/filepath"
import core_slice "core:slice"
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
	generated_orm_textures:   map[u64]Texture_Asset,
	material_texture_watches: map[string]i64,
	material_revision:        u64,
	missing_textures:         map[string]i64,
	missing_texture:          rl.Texture2D,
	diagnostics:              Diagnostic_Log,
	retained_paths:           map[string]string,
}

// init must run after raylib creates a window because it creates the small
// checkerboard texture returned when an asset cannot be loaded.
init :: proc(root: string) -> Asset_Manager {
	missing_image := rl.GenImageColor(2, 2, rl.MAGENTA)
	defer rl.UnloadImage(missing_image)
	result := Asset_Manager {
		textures                 = make(map[string]Texture_Asset),
		models                   = make(map[string]Model_Asset),
		fonts                    = make(map[string]Font_Asset),
		materials                = make(map[string]Material_Asset),
		generated_orm_textures   = make(map[u64]Texture_Asset),
		material_texture_watches = make(map[string]i64),
		material_revision        = 1,
		missing_textures         = make(map[string]i64),
		missing_texture          = rl.LoadTextureFromImage(missing_image),
		diagnostics              = init_diagnostic_log(),
		retained_paths           = make(map[string]string),
	}
	result.root = retain_path(&result, root)
	return result
}

font :: proc(
	manager: ^Asset_Manager,
	path: string,
	source_path := "",
	field := "font",
) -> (
	rl.Font,
	bool,
) {
	if len(path) == 0 {return {}, false}
	if asset, found := manager.fonts[path]; found {return asset.font, true}
	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	loaded := rl.LoadFont(path_cstring)
	delete(path_cstring)
	if !rl.IsFontValid(loaded) {
		report_failure(
			manager,
			Diagnostic {
				kind = .Font,
				operation = .Load,
				source_path = source_path,
				field = field,
				asset_path = path,
				detail = "raylib could not load the font",
			},
		)
		return {}, false
	}
	resolve_asset_failure(manager, source_path, field, path)
	manager.fonts[retain_path(manager, path)] = Font_Asset {
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
	if current_time < 0 {
		report_failure(
			manager,
			Diagnostic {
				kind = .Model,
				operation = .Load,
				field = "ModelRenderer.model",
				asset_path = path,
				detail = "model file does not exist",
			},
		)
		return 0, false
	}
	resolve_asset_failure(manager, "", "ModelRenderer.model", path)
	manager.models[retain_path(manager, path)] = Model_Asset {
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
	if !loaded {
		report_failure(
			manager,
			Diagnostic {
				kind = .Material,
				operation = .Load,
				source_path = path,
				field = "$",
				asset_path = path,
				detail = "could not read or parse material JSON",
			},
		)
		return {}, false
	}
	resolve_asset_failure(manager, path, "$", path)
	manager.materials[retain_path(manager, path)] = Material_Asset {
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
texture :: proc(
	manager: ^Asset_Manager,
	path: string,
	source_path := "",
	field := "texture",
) -> (
	rl.Texture2D,
	bool,
) {
	if len(path) == 0 {
		return manager.missing_texture, false
	}
	if asset, found := manager.textures[path]; found {
		return asset.texture, true
	}
	if _, missing := manager.missing_textures[path]; missing {
		report_failure(
			manager,
			Diagnostic {
				kind = .Texture,
				operation = .Load,
				source_path = source_path,
				field = field,
				asset_path = path,
				detail = "raylib could not load the texture",
			},
		)
		return manager.missing_texture, false
	}

	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	loaded := rl.LoadTexture(path_cstring)
	delete(path_cstring)
	if !rl.IsTextureValid(loaded) {
		manager.missing_textures[retain_path(manager, path)] = modified_time(full_path)
		report_failure(
			manager,
			Diagnostic {
				kind = .Texture,
				operation = .Load,
				source_path = source_path,
				field = field,
				asset_path = path,
				detail = "raylib could not load the texture",
			},
		)
		return manager.missing_texture, false
	}
	resolve_asset_failure(manager, source_path, field, path)
	manager.textures[retain_path(manager, path)] = Texture_Asset {
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
	source_path := "",
	field := "texture",
) -> (
	rl.Texture2D,
	bool,
) {
	loaded_texture, loaded := texture(manager, path, source_path, field)
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
	material_path := "",
) -> (
	rl.Texture2D,
	bool,
) {
	if manager == nil {return {}, false}
	if len(data.orm_texture) > 0 {
		return material_texture(
			manager,
			data.orm_texture,
			data.filter,
			data.mipmaps,
			material_path,
			"$.orm",
		)
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
	texture, loaded := generate_orm_texture(manager, data, material_path)
	if !loaded {return {}, false}
	manager.generated_orm_textures[key] = Texture_Asset {
		texture = texture,
	}
	return texture, true
}

generated_orm_key :: proc(manager: ^Asset_Manager, data: Material_Data) -> u64 {
	result := hash_string(0xcbf29ce484222325, data.ao_texture)
	ao_time := path_modified_time(manager, data.ao_texture)
	result = hash_value(result, ao_time)
	result = hash_string(result, data.roughness_texture)
	roughness_time := path_modified_time(manager, data.roughness_texture)
	result = hash_value(result, roughness_time)
	result = hash_string(result, data.metallic_texture)
	metallic_time := path_modified_time(manager, data.metallic_texture)
	result = hash_value(result, metallic_time)
	result = hash_value(result, data.roughness)
	result = hash_value(result, data.metallic)
	result = hash_string(result, data.filter)
	result = hash_value(result, data.mipmaps)
	return result
}

generate_orm_texture :: proc(
	manager: ^Asset_Manager,
	data: Material_Data,
	material_path: string,
) -> (
	rl.Texture2D,
	bool,
) {
	ao_image, has_ao := load_material_image(
		manager,
		data.ao_texture,
		material_path,
		"$.ao_texture",
	)
	roughness_image, has_roughness := load_material_image(
		manager,
		data.roughness_texture,
		material_path,
		"$.roughness_texture",
	)
	metallic_image, has_metallic := load_material_image(
		manager,
		data.metallic_texture,
		material_path,
		"$.metallic_texture",
	)
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

load_material_image :: proc(
	manager: ^Asset_Manager,
	path, source_path, field: string,
) -> (
	rl.Image,
	bool,
) {
	if len(path) == 0 {return {}, false}
	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	defer delete(path_cstring)
	image := rl.LoadImage(path_cstring)
	if !rl.IsImageValid(image) {
		report_failure(
			manager,
			Diagnostic {
				kind = .Texture,
				operation = .Load,
				source_path = source_path,
				field = field,
				asset_path = path,
				detail = "raylib could not load the material channel image; using its scalar fallback",
			},
		)
		return {}, false
	}
	resolve_asset_failure(manager, source_path, field, path)
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
	recovered_textures := make([dynamic]string)
	defer delete(recovered_textures)
	for path, failed_time in manager.missing_textures {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == failed_time {continue}
		path_cstring, _ := strings.clone_to_cstring(full_path)
		loaded := rl.LoadTexture(path_cstring)
		delete(path_cstring)
		if !rl.IsTextureValid(loaded) {
			manager.missing_textures[path] = current_time
			continue
		}
		manager.textures[path] = Texture_Asset {
			texture       = loaded,
			modified_time = current_time,
		}
		append(&recovered_textures, path)
		resolve_asset_path_failures(manager, path)
		orm_sources_changed = true
	}
	for path in recovered_textures {
		delete_key(&manager.missing_textures, path)
	}
	for path, asset in manager.textures {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time {continue}
		path_cstring, _ := strings.clone_to_cstring(full_path)
		replacement := rl.LoadTexture(path_cstring)
		delete(path_cstring)
		if !rl.IsTextureValid(replacement) {
			report_failure(
				manager,
				Diagnostic {
					kind = .Texture,
					operation = .Reload,
					field = "texture",
					asset_path = path,
					detail = "replacement is invalid; keeping the previous texture",
				},
			)
			continue
		}
		resolve_asset_path_failures(manager, path)
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
		delete(path_cstring)
		if !rl.IsFontValid(replacement) {
			report_failure(
				manager,
				Diagnostic {
					kind = .Font,
					operation = .Reload,
					field = "font",
					asset_path = path,
					detail = "replacement is invalid; keeping the previous font",
				},
			)
			continue
		}
		resolve_asset_path_failures(manager, path)
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
		if !loaded {
			report_failure(
				manager,
				Diagnostic {
					kind = .Material,
					operation = .Reload,
					source_path = path,
					field = "$",
					asset_path = path,
					detail = "invalid material JSON; keeping the previous material",
				},
			)
			continue
		}
		resolve_asset_failure(manager, path, "$", path)
		previous_data := asset.data
		manager.materials[path] = Material_Asset {
			data          = data,
			modified_time = current_time,
		}
		destroy_material_data(&previous_data)
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
		owned_path := retain_path(manager, path)
		manager.material_texture_watches[owned_path] = modified_time(resolve_path(manager, path))
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

material_data_signature :: proc(data: Material_Data) -> u64 {
	result := hash_value(0xcbf29ce484222325, data.base_color)
	result = hash_string(result, data.texture)
	result = hash_string(result, data.normal)
	result = hash_string(result, data.emission)
	result = hash_string(result, data.orm_texture)
	result = hash_string(result, data.roughness_texture)
	result = hash_string(result, data.metallic_texture)
	result = hash_string(result, data.ao_texture)
	result = hash_string(result, data.height_texture)
	result = hash_string(result, data.filter)
	result = hash_value(result, data.mipmaps)
	result = hash_value(result, data.lod_bias)
	result = hash_value(result, data.lighting)
	result = hash_value(result, data.emission_color)
	result = hash_value(result, data.emission_energy)
	result = hash_value(result, data.normal_scale)
	result = hash_value(result, data.ao_strength)
	result = hash_value(result, data.roughness)
	result = hash_value(result, data.metallic)
	result = hash_value(result, data.specular)
	result = hash_value(result, data.alpha_cutoff)
	result = hash_string(result, data.transparency)
	result = hash_string(result, data.blend)
	result = hash_string(result, data.cull)
	result = hash_value(result, data.height_scale)
	return result
}

hash_string :: proc(seed: u64, value: string) -> u64 {
	length := len(value)
	result := hash_value(seed, length)
	return hash.fnv64a(transmute([]byte)value, result)
}

hash_value :: proc(seed: u64, value: $T) -> u64 {
	copy := value
	return hash.fnv64a(core_slice.bytes_from_ptr(rawptr(&copy), size_of(T)), seed)
}

retain_path :: proc(manager: ^Asset_Manager, path: string) -> string {
	if len(path) == 0 {return ""}
	if owned, found := manager.retained_paths[path]; found {return owned}
	owned, _ := strings.clone(path)
	manager.retained_paths[owned] = owned
	return owned
}

destroy_retained_paths :: proc(manager: ^Asset_Manager) {
	paths := make([dynamic]string)
	defer delete(paths)
	for path in manager.retained_paths {append(&paths, path)}
	delete(manager.retained_paths)
	manager.retained_paths = nil
	for path in paths {delete(path)}
}

resolve_path :: proc(manager: ^Asset_Manager, path: string) -> string {
	if filepath.is_abs(path) {return retain_path(manager, path)}
	full_path, _ := filepath.join({manager.root, path})
	owned := retain_path(manager, full_path)
	delete(full_path)
	return owned
}

load_material_data :: proc(full_path: string) -> (Material_Data, bool) {
	file_data, read_error := os.read_entire_file(full_path, context.allocator)
	if read_error != nil {return {}, false}
	defer delete(file_data)
	value: json.Value
	if json.unmarshal(file_data, &value) != nil {return {}, false}
	defer json.destroy_value(value)
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
	return clone_material_data(result), true
}

clone_material_data :: proc(data: Material_Data) -> Material_Data {
	result := data
	result.texture = clone_asset_string(data.texture)
	result.normal = clone_asset_string(data.normal)
	result.emission = clone_asset_string(data.emission)
	result.orm_texture = clone_asset_string(data.orm_texture)
	result.roughness_texture = clone_asset_string(data.roughness_texture)
	result.metallic_texture = clone_asset_string(data.metallic_texture)
	result.ao_texture = clone_asset_string(data.ao_texture)
	result.height_texture = clone_asset_string(data.height_texture)
	result.filter = clone_asset_string(data.filter)
	result.transparency = clone_asset_string(data.transparency)
	result.blend = clone_asset_string(data.blend)
	result.cull = clone_asset_string(data.cull)
	return result
}

destroy_material_data :: proc(data: ^Material_Data) {
	if data == nil {return}
	delete(data.texture)
	delete(data.normal)
	delete(data.emission)
	delete(data.orm_texture)
	delete(data.roughness_texture)
	delete(data.metallic_texture)
	delete(data.ao_texture)
	delete(data.height_texture)
	delete(data.filter)
	delete(data.transparency)
	delete(data.blend)
	delete(data.cull)
	data^ = {}
}

clone_asset_string :: proc(value: string) -> string {
	if len(value) == 0 {return ""}
	result, _ := strings.clone(value)
	return result
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
	if manager == nil {return}
	clear_generated_orm_textures(manager)
	for _, asset in manager.textures {
		rl.UnloadTexture(asset.texture)
	}
	for _, asset in manager.fonts {
		rl.UnloadFont(asset.font)
	}
	for _, asset in manager.materials {
		data := asset.data
		destroy_material_data(&data)
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
	destroy_diagnostic_log(&manager.diagnostics)
	destroy_retained_paths(manager)
	manager^ = {}
}
