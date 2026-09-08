package ecs

import "core:encoding/json"

Shape_2D :: enum {rectangle, circle}

ShapeRenderer2D :: struct {
	shape: Shape_2D,
	size: [2]f32,
	radius: f32,
	origin: [2]f32,
	color: Color,
	filled: bool,
	line_width: f32,
	draw_order: i32,
}

default_shape_renderer_2d :: proc() -> ShapeRenderer2D {
	return {shape = .rectangle, size = {32, 32}, radius = 16,
	        origin = {0.5, 0.5}, color = {255, 255, 255, 255}, filled = true, line_width = 1}
}

shape_renderer_2d_from_json :: proc(data: json.Value) -> (ShapeRenderer2D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := default_shape_renderer_2d()
	for key, value in object {
		switch key {
		case "shape":
			name, valid := value.(json.String)
			if !valid {return {}, false}
			switch name {
			case "rectangle": result.shape = .rectangle
			case "circle": result.shape = .circle
			case: return {}, false
			}
		case "size": if !read_vector2(value, &result.size) {return {}, false}
		case "origin": if !read_vector2(value, &result.origin) {return {}, false}
		case "radius": result.radius, ok = read_number(value); if !ok {return {}, false}
		case "color": if !read_color(value, &result.color) {return {}, false}
		case "filled": result.filled, ok = value.(json.Boolean); if !ok {return {}, false}
		case "line_width": result.line_width, ok = read_number(value); if !ok {return {}, false}
		case "draw_order": if !read_draw_order(value, &result.draw_order) {return {}, false}
		case: return {}, false
		}
	}
	return result, component_value_valid(result)
}

get_shape_renderer_2d :: proc(world: ^World, entity: Entity) -> (ShapeRenderer2D, bool) {
	value, found := world.shape_renderers_2d[entity]
	return value, found
}

set_shape_renderer_2d :: proc(world: ^World, entity: Entity, value: ShapeRenderer2D) -> bool {
	if !has_component_data(world, entity, "ShapeRenderer2D") || !component_value_valid(value) {return false}
	commit_component_value(world, entity, "ShapeRenderer2D", &world.shape_renderers_2d, value)
	return true
}
