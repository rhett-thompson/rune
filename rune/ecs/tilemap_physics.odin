package ecs

import "core:encoding/json"
import "core:math"

TilemapCollider :: struct {
	solid_tiles: map[i32]bool,
}

TopDownController :: struct {
	size:  [2]f32,
	speed: f32,
}

tilemap_collider_from_json :: proc(data: json.Value) -> (TilemapCollider, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	value, found := object["solid_tiles"]
	if !found {return {}, false}
	array, array_ok := value.(json.Array)
	if !array_ok {return {}, false}
	solid_tiles := make(map[i32]bool)
	for entry in array {
		tile, tile_ok := read_number(entry)
		if !tile_ok || tile < 0 || tile != f32(i32(tile)) {return {}, false}
		solid_tiles[i32(tile)] = true
	}
	return TilemapCollider{solid_tiles = solid_tiles}, len(solid_tiles) > 0
}

top_down_controller_from_json :: proc(data: json.Value) -> (TopDownController, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := TopDownController {
		size  = {16, 16},
		speed = 180,
	}
	if value, found := object["size"];
	   found && !read_vector2(value, &result.size) {return {}, false}
	if value, found := object["speed"];
	   found {result.speed, ok = read_number(value); if !ok || result.speed <= 0 {return {}, false}}
	if result.size[0] <= 0 || result.size[1] <= 0 {return {}, false}
	return result, true
}

// move_top_down moves an entity by the requested X/Y delta. It resolves each
// axis independently so the entity slides along solid tilemap walls.
move_top_down :: proc(world: ^World, entity: Entity, delta: [2]f32) -> bool {
	transform, has_transform := get_transform(world, entity)
	controller, has_controller := get_top_down_controller(world, entity)
	if !has_transform || !has_controller {return false}
	position := transform.position
	if !top_down_blocked(world, entity, controller, {position[0] + delta[0], position[1]}) {
		position[0] += delta[0]
	}
	if !top_down_blocked(world, entity, controller, {position[0], position[1] + delta[1]}) {
		position[1] += delta[1]
	}
	transform.position[0] = position[0]
	transform.position[1] = position[1]
	set_transform(world, entity, transform)
	return true
}

top_down_blocked :: proc(
	world: ^World,
	entity: Entity,
	controller: TopDownController,
	position: [2]f32,
) -> bool {
	player_min := [2]f32 {
		position[0] - controller.size[0] * 0.5,
		position[1] - controller.size[1] * 0.5,
	}
	player_max := [2]f32 {
		position[0] + controller.size[0] * 0.5,
		position[1] + controller.size[1] * 0.5,
	}
	for map_entity, collider in world.tilemap_colliders {
		if !collides_by_layer(world, entity, map_entity) {continue}
		tilemap, has_tilemap := get_tilemap_renderer(world, map_entity)
		map_transform, has_transform := get_transform(world, map_entity)
		if !has_tilemap ||
		   !has_transform ||
		   tilemap.tile_size[0] <= 0 ||
		   tilemap.tile_size[1] <= 0 ||
		   map_transform.scale[0] <= 0 ||
		   map_transform.scale[1] <= 0 {continue}
		tile_width := tilemap.tile_size[0] * map_transform.scale[0]
		tile_height := tilemap.tile_size[1] * map_transform.scale[1]
		min_x := i32(math.floor(f64((player_min[0] - map_transform.position[0]) / tile_width)))
		max_x := i32(math.floor(f64((player_max[0] - map_transform.position[0]) / tile_width)))
		min_y := i32(math.floor(f64((player_min[1] - map_transform.position[1]) / tile_height)))
		max_y := i32(math.floor(f64((player_max[1] - map_transform.position[1]) / tile_height)))
		for y := min_y; y <= max_y; y += 1 {
			for x := min_x; x <= max_x; x += 1 {
				index, has_tile := tilemap.tile_indices[{x, y}]
				if !has_tile || !tile_is_solid(collider, index) {continue}
				tile_min := [2]f32 {
					map_transform.position[0] + f32(x) * tile_width,
					map_transform.position[1] + f32(y) * tile_height,
				}
				tile_max := tile_min + [2]f32{tile_width, tile_height}
				if player_min[0] < tile_max[0] &&
				   player_max[0] > tile_min[0] &&
				   player_min[1] < tile_max[1] &&
				   player_max[1] > tile_min[1] {
					return true
				}
			}
		}
	}
	return false
}

tile_is_solid :: proc(collider: TilemapCollider, index: i32) -> bool {
	return collider.solid_tiles[index]
}
