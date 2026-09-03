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
		tilemap.texture = data.texture
		tilemap.tile_size = {f32(data.tile_size[0]), f32(data.tile_size[1])}
		tilemap.tileset_revision = revision
		ecs.set_tilemap_renderer(world, entity, tilemap)
	}
}
