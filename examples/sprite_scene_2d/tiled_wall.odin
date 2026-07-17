package main

import "rune:assets"
import "rune:ecs"
import rl "vendor:raylib"

Tiled_Wall :: struct {
	texture:    string,
	tile_scale: f32,
}

// TiledWall is a game-owned typed component. JSON initializes its struct data;
// this example supplies the behavior that renders it.
draw_tiled_walls :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager) {
	for entity in ecs.query(world, Tiled_Wall) {
		wall_data, found := ecs.get(world, entity, Tiled_Wall)
		if !found || len(wall_data.texture) == 0 || wall_data.tile_scale <= 0 { continue }
		draw_tiled_wall_component(asset_manager, wall_data)
	}
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
