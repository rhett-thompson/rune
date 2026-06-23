package ecs

import "core:encoding/json"

Color :: struct { r, g, b, a: u8 }

SpriteRenderer :: struct {
	texture: string,
	origin:  [2]f32,
}

MeshRenderer :: struct {
	primitive: string,
	color:     Color,
}

SphereRenderer :: struct {
	radius: f32,
	color:  Color,
}

ModelRenderer :: struct {
	model: string,
	tint:  Color,
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
	result := MeshRenderer{color = {255, 255, 255, 255}}
	if value, found := object["primitive"]; found {
		result.primitive, ok = value.(json.String)
		if !ok { return {}, false }
	}
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
	return result, true
}

sphere_renderer_from_json :: proc(data: json.Value) -> (SphereRenderer, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := SphereRenderer{radius = 1, color = {255, 255, 255, 255}}
	if value, found := object["radius"]; found {
		result.radius, ok = read_number(value)
		if !ok || result.radius <= 0 { return {}, false }
	}
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
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
