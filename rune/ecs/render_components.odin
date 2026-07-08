package ecs

import "core:encoding/json"
import "core:strconv"

Color :: struct { r, g, b, a: u8 }

SpriteRenderer :: struct {
	texture: string,
	origin:  [2]f32,
}

MeshRenderer :: struct {
	primitive: string,
	color:     Color,
	material:  string,
	shadows:   bool,
}

SphereRenderer :: struct {
	radius: f32,
	color:  Color,
	material: string,
	shadows: bool,
}

ModelRenderer :: struct {
	model:    string,
	tint:     Color,
	material: string,
	materials: map[i32]string,
}

Tilemap_Tile :: struct { x, y, index: i32 }

TilemapRenderer :: struct {
	texture:      string,
	tile_size:    [2]f32,
	grid_size:    [2]i32,
	tiles:        []Tilemap_Tile,
	tile_indices: map[[2]i32]i32,
}

TextRenderer :: struct {
	text:      string,
	font:      string,
	font_size: f32,
	spacing:   f32,
	color:     Color,
	origin:    [2]f32,
}

sprite_renderer_from_json :: proc(data: json.Value) -> (SpriteRenderer, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := SpriteRenderer{origin = {0.5, 0.5}}
	if value, found := object["texture"]; found {
		result.texture, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["origin"]; found && !read_vector2(value, &result.origin) { return {}, false }
	return result, true
}

mesh_renderer_from_json :: proc(data: json.Value) -> (MeshRenderer, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := MeshRenderer{color = {255, 255, 255, 255}, shadows = true}
	if value, found := object["primitive"]; found {
		result.primitive, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
	if value, found := object["material"]; found {
		result.material, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["shadows"]; found {
		result.shadows, ok = value.(json.Boolean)
		if !ok { return {}, false }
	}
	return result, true
}

sphere_renderer_from_json :: proc(data: json.Value) -> (SphereRenderer, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := SphereRenderer{radius = 1, color = {255, 255, 255, 255}, shadows = true}
	if value, found := object["radius"]; found {
		result.radius, ok = read_number(value)
		if !ok || result.radius <= 0 { return {}, false }
	}
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
	if value, found := object["material"]; found {
		result.material, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["shadows"]; found {
		result.shadows, ok = value.(json.Boolean)
		if !ok { return {}, false }
	}
	return result, true
}

model_renderer_from_json :: proc(data: json.Value) -> (ModelRenderer, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := ModelRenderer{tint = {255, 255, 255, 255}}
	model, found := object["model"]
	if !found { return {}, false }
	result.model, ok = model.(json.String)
	if !ok || len(result.model) == 0 { return {}, false }
	if value, found := object["tint"]; found && !read_color(value, &result.tint) { return {}, false }
	if value, found := object["material"]; found {
		result.material, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["materials"]; found {
		materials, materials_ok := value.(json.Object)
		if !materials_ok { return {}, false }
		result.materials = make(map[i32]string)
		for key, material_value in materials {
			slot, slot_ok := strconv.parse_int(key, 10)
			if !slot_ok || slot < 0 || slot > 2147483647 { return {}, false }
			material_path, path_ok := material_value.(json.String)
			if !path_ok || len(material_path) == 0 { return {}, false }
			result.materials[i32(slot)] = material_path
		}
	}
	return result, true
}

tilemap_renderer_from_json :: proc(data: json.Value) -> (TilemapRenderer, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := TilemapRenderer{}
	texture, has_texture := object["texture"]
	if !has_texture { return {}, false }
	result.texture, ok = texture.(json.String)
	if !ok || len(result.texture) == 0 { return {}, false }
	if value, found := object["tile_size"]; !found || !read_vector2(value, &result.tile_size) { return {}, false }
	if result.tile_size[0] <= 0 || result.tile_size[1] <= 0 { return {}, false }
	grid, has_grid := object["grid"]
	if !has_grid { return {}, false }
	rows, rows_ok := grid.(json.Array)
	if !rows_ok { return {}, false }
	tiles := make([dynamic]Tilemap_Tile, context.allocator)
	result.tile_indices = make(map[[2]i32]i32)
	for row_value, y in rows {
		row, row_ok := row_value.(json.Array)
		if !row_ok { return {}, false }
		if i32(len(row)) > result.grid_size[0] { result.grid_size[0] = i32(len(row)) }
		result.grid_size[1] += 1
		for cell_value, x in row {
			index, index_ok := read_number(cell_value)
			if !index_ok || index != f32(i32(index)) || index < -1 { return {}, false }
			if index >= 0 {
				tile := Tilemap_Tile{x = i32(x), y = i32(y), index = i32(index)}
				append(&tiles, tile)
				result.tile_indices[{tile.x, tile.y}] = tile.index
			}
		}
	}
	result.tiles = tiles[:]
	return result, true
}

text_renderer_from_json :: proc(data: json.Value) -> (TextRenderer, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := TextRenderer{font_size = 20, color = {255, 255, 255, 255}}
	text, has_text := object["text"]
	font, has_font := object["font"]
	if !has_text || !has_font { return {}, false }
	result.text, ok = text.(json.String)
	if !ok { return {}, false }
	result.font, ok = font.(json.String)
	if !ok || len(result.font) == 0 { return {}, false }
	if value, found := object["font_size"]; found { result.font_size, ok = read_number(value); if !ok || result.font_size <= 0 { return {}, false } }
	if value, found := object["spacing"]; found { result.spacing, ok = read_number(value); if !ok { return {}, false } }
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
	if value, found := object["origin"]; found && !read_vector2(value, &result.origin) { return {}, false }
	return result, true
}

read_vector2 :: proc(data: json.Value, result: ^[2]f32) -> bool {
	array, ok := data.(json.Array)
	if !ok || len(array) != 2 { return false }
	for value, index in array {
		number, number_ok := read_number(value)
		if !number_ok { return false }
		result[index] = number
	}
	return true
}

read_color :: proc(data: json.Value, result: ^Color) -> bool {
	array, ok := data.(json.Array)
	if !ok || len(array) != 4 { return false }
	values := [4]^u8{&result.r, &result.g, &result.b, &result.a}
	for value, index in array {
		number, number_ok := read_number(value)
		if !number_ok || number < 0 || number > 255 || number != f32(i32(number)) { return false }
		values[index]^ = u8(number)
	}
	return true
}
