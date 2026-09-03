package assets

import "core:encoding/json"
import "core:os"
import "core:strconv"
import "core:strings"
import "rune:jsonutil"

Tileset_Tile :: struct {
	name:   string,
	source: [2]i32,
	size:   [2]i32,
}

Tileset_Data :: struct {
	texture:   string,
	tile_size: [2]i32,
	tiles:     map[i32]Tileset_Tile,
	max_size:  [2]i32,
}

Tileset_Asset :: struct {
	data:          Tileset_Data,
	modified_time: i64,
	revision:      u64,
}

tileset :: proc(manager: ^Asset_Manager, path: string) -> (Tileset_Data, u64, bool) {
	if manager == nil || len(path) == 0 {return {}, 0, false}
	if asset, found := manager.tilesets[path]; found {
		return asset.data, asset.revision, true
	}
	full_path := resolve_path(manager, path)
	data, loaded := load_tileset_data(full_path)
	if !loaded {
		report_failure(
			manager,
			Diagnostic {
				kind = .Tileset,
				operation = .Load,
				source_path = path,
				field = "$",
				asset_path = path,
				detail = "could not read or parse tileset JSON",
			},
		)
		return {}, 0, false
	}
	resolve_asset_failure(manager, path, "$", path)
	manager.tilesets[retain_path(manager, path)] = Tileset_Asset {
		data          = data,
		modified_time = modified_time(full_path),
		revision      = 1,
	}
	return data, 1, true
}

// load_tileset_data is window-independent so validators and asset tools can
// inspect tilesets without initializing raylib.
load_tileset_data :: proc(full_path: string) -> (Tileset_Data, bool) {
	file_data, read_error := os.read_entire_file(full_path, context.allocator)
	if read_error != nil {return {}, false}
	defer delete(file_data)
	value: json.Value
	if json.unmarshal(file_data, &value) != nil {return {}, false}
	defer json.destroy_value(value)
	object, ok := value.(json.Object)
	if !ok {return {}, false}
	texture_value, has_texture := object["texture"]
	tile_size_value, has_tile_size := object["tile_size"]
	tiles_value, has_tiles := object["tiles"]
	if !has_texture || !has_tile_size || !has_tiles {return {}, false}
	texture, texture_ok := texture_value.(json.String)
	if !texture_ok || len(texture) == 0 {return {}, false}
	tile_size, size_ok := read_tileset_vector2(tile_size_value, false)
	if !size_ok {return {}, false}
	tiles_object, tiles_ok := tiles_value.(json.Object)
	if !tiles_ok || len(tiles_object) == 0 {return {}, false}

	result := Tileset_Data {
		texture   = clone_asset_string(texture),
		tile_size = tile_size,
		tiles     = make(map[i32]Tileset_Tile),
		max_size  = {1, 1},
	}
	valid := false
	defer if !valid {destroy_tileset_data(&result)}
	for key, tile_value in tiles_object {
		index_64, index_ok := strconv.parse_int(key, 10)
		if !index_ok || index_64 < 0 || index_64 > 2147483647 {return {}, false}
		index := i32(index_64)
		if _, duplicate := result.tiles[index]; duplicate {return {}, false}
		tile_object, tile_ok := tile_value.(json.Object)
		if !tile_ok {return {}, false}
		source_value, has_source := tile_object["source"]
		if !has_source {return {}, false}
		source, source_ok := read_tileset_vector2(source_value, true)
		if !source_ok {return {}, false}
		tile := Tileset_Tile {
			source = source,
			size   = {1, 1},
		}
		if size_value, found := tile_object["size"]; found {
			tile.size, size_ok = read_tileset_vector2(size_value, false)
			if !size_ok {return {}, false}
		}
		if name_value, found := tile_object["name"]; found {
			name, name_ok := name_value.(json.String)
			if !name_ok || len(name) == 0 {return {}, false}
			tile.name = clone_asset_string(name)
		}
		if tile.size[0] > result.max_size[0] {result.max_size[0] = tile.size[0]}
		if tile.size[1] > result.max_size[1] {result.max_size[1] = tile.size[1]}
		result.tiles[index] = tile
	}
	valid = true
	return result, true
}

read_tileset_vector2 :: proc(value: json.Value, allow_zero: bool) -> ([2]i32, bool) {
	array, ok := value.(json.Array)
	if !ok || len(array) != 2 {return {}, false}
	result: [2]i32
	for coordinate_value, index in array {
		coordinate, coordinate_ok := jsonutil.number(coordinate_value)
		minimum: f32 = 1
		if allow_zero {minimum = 0}
		if !coordinate_ok || coordinate < minimum || coordinate != f32(i32(coordinate)) {
			return {}, false
		}
		result[index] = i32(coordinate)
	}
	return result, true
}

refresh_tilesets :: proc(manager: ^Asset_Manager) {
	if manager == nil {return}
	for path, asset in manager.tilesets {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time {continue}
		data, loaded := load_tileset_data(full_path)
		if !loaded {
			report_failure(
				manager,
				Diagnostic {
					kind = .Tileset,
					operation = .Reload,
					source_path = path,
					field = "$",
					asset_path = path,
					detail = "invalid tileset JSON; keeping the previous tileset",
				},
			)
			continue
		}
		resolve_asset_path_failures(manager, path)
		previous_data := asset.data
		updated_asset := asset
		updated_asset.data = data
		updated_asset.modified_time = current_time
		updated_asset.revision += 1
		if updated_asset.revision == 0 {updated_asset.revision = 1}
		manager.tilesets[path] = updated_asset
		destroy_tileset_data(&previous_data)
	}
}

destroy_tileset_data :: proc(data: ^Tileset_Data) {
	if data == nil {return}
	delete(data.texture)
	for _, tile in data.tiles {delete(tile.name)}
	delete(data.tiles)
	data^ = {}
}
