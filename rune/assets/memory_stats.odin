package assets

import "rune:memory"
import rl "vendor:raylib"

Memory_Stats :: struct {
	textures, fonts, models, materials, retained_paths: int,
	map_bytes, retained_path_bytes, texture_gpu_bytes_estimate: u64,
}

// Texture payload estimates include mipmaps, but exclude driver overhead,
// render targets, imported model textures, and other renderer-owned resources.
texture_bytes_estimate :: proc(texture: rl.Texture2D) -> u64 {
	if texture.id == 0 || texture.width <= 0 || texture.height <= 0 {return 0}
	w, h := texture.width, texture.height
	bytes: u64
	for _ in 0..<max(1, texture.mipmaps) {
		bytes += u64(max(0, rl.GetPixelDataSize(w, h, texture.format)))
		w, h = max(1, w/2), max(1, h/2)
	}
	return bytes
}

memory_stats :: proc(manager: ^Asset_Manager) -> Memory_Stats {
	if manager == nil {return {}}
	result := Memory_Stats{
		textures = len(manager.textures), fonts = len(manager.fonts),
		models = len(manager.models), materials = len(manager.materials), retained_paths = len(manager.retained_paths),
	}
	result.map_bytes = memory.map_bytes(manager.textures) + memory.map_bytes(manager.fonts) + memory.map_bytes(manager.models)
	result.map_bytes += memory.map_bytes(manager.materials) + memory.map_bytes(manager.retained_paths) + memory.map_bytes(manager.generated_orm_textures)
	result.map_bytes += memory.map_bytes(manager.skyboxes) + memory.map_bytes(manager.terrains) + memory.map_bytes(manager.animations)
	result.map_bytes += memory.map_bytes(manager.tilesets) + memory.map_bytes(manager.navmeshes) + memory.map_bytes(manager.model_events)
	result.map_bytes += memory.map_bytes(manager.shadow_profiles) + memory.map_bytes(manager.material_texture_watches) + memory.map_bytes(manager.missing_textures)
	for path in manager.retained_paths {result.retained_path_bytes += u64(len(path))}
	for _, asset in manager.textures {result.texture_gpu_bytes_estimate += texture_bytes_estimate(asset.texture)}
	for _, asset in manager.fonts {result.texture_gpu_bytes_estimate += texture_bytes_estimate(asset.font.texture)}
	for _, asset in manager.generated_orm_textures {result.texture_gpu_bytes_estimate += texture_bytes_estimate(asset.texture)}
	result.texture_gpu_bytes_estimate += texture_bytes_estimate(manager.missing_texture)
	return result
}
