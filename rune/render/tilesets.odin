package render

import "rune:assets"
import "rune:ecs"

// update_tilesets resolves reusable tileset settings before fixed-step
// collision runs. Rendering also resolves the asset directly, but physics only
// needs the shared texture-independent tile size stored on the component.
update_tilesets :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager) {
	if world == nil || asset_manager == nil {return}
	for entity in ecs.entities_with_component(world, "TilemapRenderer") {
		tilemap, found := ecs.get_tilemap_renderer(world, entity)
		if !found || len(tilemap.tileset) == 0 {continue}
		data, revision, loaded := assets.tileset(asset_manager, tilemap.tileset)
		if !loaded || tilemap.tileset_revision == revision {continue}
		tile_sizes := make(map[i32][2]i32)
		tile_collisions := make(map[i32]ecs.Tilemap_Collision_Rect)
		for index, tile in data.tiles {
			tile_sizes[index] = tile.size
			if tile.has_collision {
				tile_collisions[index] = {
					offset = tile.collision.offset,
					size   = tile.collision.size,
				}
			}
		}
		tilemap.texture = data.texture
		tilemap.tile_size = {f32(data.tile_size[0]), f32(data.tile_size[1])}
		tilemap.tile_sizes = tile_sizes
		tilemap.tile_collisions = tile_collisions
		tilemap.max_tile_size = data.max_size
		tilemap.tileset_revision = revision
		ecs.set_tilemap_renderer(world, entity, tilemap)
		delete(tile_sizes)
		delete(tile_collisions)
	}
}
