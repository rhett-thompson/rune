package main

import "core:fmt"
import "rune:assets"
import "rune:ecs"
import "rune:scene"

main :: proc() {
	data, loaded := assets.load_tileset_data("examples/tilemap_2d/assets/world.tileset.json")
	assert(loaded)
	defer assets.destroy_tileset_data(&data)
	assert(data.texture == "../assets/brackeys_platformer_assets/sprites/world_tileset.png")
	assert(data.tile_size == {16, 16})
	assert(data.max_size == {2, 4})
	grass, has_grass := data.tiles[0]
	tree, has_tree := data.tiles[100]
	assert(has_grass && grass.name == "grass_block" && grass.size == {1, 1})
	assert(has_tree && tree.name == "large_tree")
	assert(tree.source == {0, 3} && tree.size == {2, 4})

	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, scene_loaded := scene.load("examples/tilemap_2d/scenes/main.scene.json", &registry)
	assert(scene_loaded)
	defer ecs.destroy(&world)
	dungeon, found := ecs.find_entity_by_id(&world, "dungeon")
	assert(found)
	tilemap, has_tilemap := ecs.get_tilemap_renderer(&world, dungeon)
	assert(has_tilemap && tilemap.tileset == "assets/world.tileset.json")
	assert(tilemap.tile_indices[{3, 1}] == 100)

	fmt.println("tileset validation passed")
}
