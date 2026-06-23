package main

import "core:encoding/json"
import "rune:assets"
import "rune:ecs"
import "rune:jsonutil"
import rl "vendor:raylib"

Tiled_Wall :: struct {
	texture:    string,
	tile_scale: f32,
}

// TiledWall is a game-owned component. The scene loader automatically stores
// its JSON data; this example supplies the behavior that renders it.
draw_tiled_walls :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager) {
	for entity in ecs.entities_with_component(world, "TiledWall") {
		component, found := ecs.get_component(world, entity, "TiledWall")
		if !found { continue }
		wall_data, valid := tiled_wall_from_json(component)
		if !valid { continue }
		draw_tiled_wall_component(asset_manager, wall_data)
	}
}

tiled_wall_from_json :: proc(data: json.Value) -> (Tiled_Wall, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	texture, texture_ok := object["texture"].(json.String)
	if !texture_ok || len(texture) == 0 { return {}, false }
	tile_scale := f32(1)
	if value, found := object["tile_scale"]; found {
		tile_scale, ok = jsonutil.number(value)
		if !ok || tile_scale <= 0 { return {}, false }
	}
	return Tiled_Wall{texture = texture, tile_scale = tile_scale}, true
}

draw_tiled_wall_component :: proc(asset_manager: ^assets.Asset_Manager, wall_data: Tiled_Wall) {
	wall, loaded := assets.texture(asset_manager, wall_data.texture)
	if !loaded { return }
	source := rl.Rectangle{0, 0, f32(wall.width), f32(wall.height)}
	tile_width := i32(source.width * wall_data.tile_scale)
	tile_height := i32(source.height * wall_data.tile_scale)
	for y: i32 = 0; y < rl.GetScreenHeight(); y += tile_height {
		for x: i32 = 0; x < rl.GetScreenWidth(); x += tile_width {
			destination := rl.Rectangle{f32(x), f32(y), f32(tile_width), f32(tile_height)}
			rl.DrawTexturePro(wall, source, destination, {}, 0, rl.WHITE)
		}
	}
}
