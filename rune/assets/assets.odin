package assets

import "core:path/filepath"
import "core:os"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

Texture_Asset :: struct {
	texture:       rl.Texture2D,
	modified_time: i64,
}

Model_Asset :: struct {
	model:         rl.Model,
	modified_time: i64,
}

// Asset paths are the first asset identifiers. Stable IDs can be layered on later.
Asset_Manager :: struct {
	root:             string,
	textures:         map[string]Texture_Asset,
	models:           map[string]Model_Asset,
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
		missing_textures = make(map[string]bool),
		missing_texture = rl.LoadTextureFromImage(missing_image),
	}
}

// model returns a cached model loaded from a project-relative path.
model :: proc(manager: ^Asset_Manager, path: string) -> (rl.Model, bool) {
	if len(path) == 0 { return {}, false }
	if asset, found := manager.models[path]; found { return asset.model, true }
	full_path := resolve_path(manager, path)
	path_cstring, _ := strings.clone_to_cstring(full_path)
	loaded := rl.LoadModel(path_cstring)
	if !rl.IsModelValid(loaded) { return {}, false }
	manager.models[path] = Model_Asset{model = loaded, modified_time = modified_time(full_path)}
	return loaded, true
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

// refresh reloads cached textures whose on-disk modified time changed. Invalid
// replacement files leave the currently working texture in place.
refresh :: proc(manager: ^Asset_Manager) {
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
		rl.UnloadModel(asset.model)
		updated_asset := asset
		updated_asset.model = replacement
		updated_asset.modified_time = current_time
		manager.models[path] = updated_asset
	}
}

resolve_path :: proc(manager: ^Asset_Manager, path: string) -> string {
	if filepath.is_abs(path) { return path }
	full_path, _ := filepath.join({manager.root, path})
	return full_path
}

modified_time :: proc(path: string) -> i64 {
	modified, err := os.modification_time_by_path(path)
	if err != nil { return -1 }
	return time.to_unix_nanoseconds(modified)
}

shutdown :: proc(manager: ^Asset_Manager) {
	for _, asset in manager.textures {
		rl.UnloadTexture(asset.texture)
	}
	for _, asset in manager.models {
		rl.UnloadModel(asset.model)
	}
	if rl.IsTextureValid(manager.missing_texture) {
		rl.UnloadTexture(manager.missing_texture)
	}
}
