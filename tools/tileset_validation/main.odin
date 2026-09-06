package main

import "core:fmt"
import "core:slice"
import "rune:assets"
import "rune:ecs"
import "rune:render"
import "rune:scene"

main :: proc() {
	data, loaded := assets.load_tileset_data("examples/tilemap_2d/assets/world.tileset.json")
	assert(loaded)
	defer assets.destroy_tileset_data(&data)
	assert(data.texture == "../assets/brackeys_platformer_assets/sprites/world_tileset.png")
	assert(data.tile_size == {16, 16})
	assert(data.max_size == {1, 3})
	grass, has_grass := data.tiles[0]
	tree, has_tree := data.tiles[100]
	assert(has_grass && grass.name == "grass_block" && grass.size == {1, 1})
	assert(has_tree && tree.name == "large_tree")
	assert(tree.source == {0, 3} && tree.size == {1, 3})
	assert(tree.has_collision)
	assert(tree.collision.offset == {0, 2} && tree.collision.size == {1, 1})

	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, scene_loaded := scene.load("examples/tilemap_2d/scenes/main.scene.json", &registry)
	assert(scene_loaded)
	defer ecs.destroy(&world)
	ground, ground_found := ecs.find_entity_by_id(&world, "ground_layer")
	objects, objects_found := ecs.find_entity_by_id(&world, "object_layer")
	foreground, foreground_found := ecs.find_entity_by_id(&world, "foreground_layer")
	assert(ground_found && objects_found && foreground_found)
	ground_tilemap, has_ground_tilemap := ecs.get_tilemap_renderer(&world, ground)
	tilemap, has_tilemap := ecs.get_tilemap_renderer(&world, objects)
	foreground_tilemap, has_foreground_tilemap := ecs.get_tilemap_renderer(&world, foreground)
	assert(has_ground_tilemap && has_tilemap && has_foreground_tilemap)
	assert(ground_tilemap.draw_order == -100)
	assert(tilemap.draw_order == 25)
	assert(foreground_tilemap.draw_order == 100)
	assert(has_tilemap && tilemap.tileset == "assets/world.tileset.json")
	assert(tilemap.tile_indices[{3, 2}] == 100)
	knight, knight_found := ecs.find_entity_by_id(&world, "knight")
	instructions, instructions_found := ecs.find_entity_by_id(&world, "instructions")
	assert(knight_found)
	assert(instructions_found)
	sprite, has_sprite := ecs.get_sprite_renderer(&world, knight)
	assert(has_sprite && sprite.draw_order == 0)

	commands := make([dynamic]render.Render_2D_Command)
	defer delete(commands)
	for root in ecs.root_entities(&world) {
		render.collect_render_commands_2d(&world, root, {0, 0}, {1, 1}, 0, &commands)
	}
	slice.sort_by(commands[:], render.render_command_2d_less)
	assert(len(commands) == 5)
	assert(commands[0].entity == ground && commands[0].draw_order == -100)
	// Trees must cover the knight when walking behind their canopy.
	assert(commands[1].entity == knight && commands[1].draw_order == 0)
	assert(commands[2].entity == objects && commands[2].draw_order == 25)
	assert(commands[3].entity == foreground && commands[3].draw_order == 100)
	assert(commands[4].entity == instructions && commands[4].draw_order == 1000)

	// Runtime tileset resolution copies these dimensions onto the renderer so
	// collision can cover every cell of a multi-cell sprite, not just its anchor.
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
	tilemap.tile_size = {f32(data.tile_size[0]), f32(data.tile_size[1])}
	tilemap.tile_sizes = tile_sizes
	tilemap.tile_collisions = tile_collisions
	tilemap.max_tile_size = data.max_size
	assert(ecs.set_tilemap_renderer(&world, objects, tilemap))
	delete(tile_sizes)
	delete(tile_collisions)

	transform, has_transform := ecs.get_transform(&world, knight)
	assert(has_transform)
	// The canopy is visual only, so movement through its upper cells succeeds.
	transform.position = {212, 120, 0}
	assert(ecs.set_transform(&world, knight, transform))
	assert(ecs.move_top_down(&world, knight, {-20, 0}))
	transform, has_transform = ecs.get_transform(&world, knight)
	assert(has_transform && transform.position == [3]f32{192, 120, 0})

	// The bottom cell is the trunk collision rectangle and still blocks.
	transform.position = {212, 216, 0}
	assert(ecs.set_transform(&world, knight, transform))
	assert(ecs.move_top_down(&world, knight, {-20, 0}))
	transform, has_transform = ecs.get_transform(&world, knight)
	assert(has_transform && transform.position == [3]f32{212, 216, 0})

	fmt.println("tileset validation passed")
}
