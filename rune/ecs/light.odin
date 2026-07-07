package ecs

import "core:encoding/json"

AmbientLight :: struct {
	color:     Color,
	intensity: f32,
}

DirectionalLight :: struct {
	direction: [3]f32,
	color:     Color,
	intensity: f32,
}

PointLight :: struct {
	color:     Color,
	intensity: f32,
	range:     f32,
}

SpotLight :: struct {
	direction:   [3]f32,
	color:       Color,
	intensity:   f32,
	range:       f32,
	inner_angle: f32,
	outer_angle: f32,
}

ambient_light_from_json :: proc(data: json.Value) -> (AmbientLight, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := AmbientLight{color = {255, 255, 255, 255}, intensity = 0.2}
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
	if value, found := object["intensity"]; found {
		result.intensity, ok = read_number(value)
		if !ok || result.intensity < 0 { return {}, false }
	}
	return result, true
}

directional_light_from_json :: proc(data: json.Value) -> (DirectionalLight, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := DirectionalLight{direction = {-0.35, -1, -0.45}, color = {255, 255, 255, 255}, intensity = 1}
	if value, found := object["direction"]; found && !read_vector3(value, &result.direction) { return {}, false }
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
	if value, found := object["intensity"]; found {
		result.intensity, ok = read_number(value)
		if !ok || result.intensity < 0 { return {}, false }
	}
	return result, true
}

point_light_from_json :: proc(data: json.Value) -> (PointLight, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := PointLight{color = {255, 255, 255, 255}, intensity = 1, range = 5}
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
	if value, found := object["intensity"]; found {
		result.intensity, ok = read_number(value)
		if !ok || result.intensity < 0 { return {}, false }
	}
	if value, found := object["range"]; found {
		result.range, ok = read_number(value)
		if !ok || result.range <= 0 { return {}, false }
	}
	return result, true
}

spot_light_from_json :: proc(data: json.Value) -> (SpotLight, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := SpotLight{
		direction = {0, -1, 0},
		color = {255, 255, 255, 255},
		intensity = 1,
		range = 8,
		inner_angle = 18,
		outer_angle = 32,
	}
	if value, found := object["direction"]; found && !read_vector3(value, &result.direction) { return {}, false }
	if value, found := object["color"]; found && !read_color(value, &result.color) { return {}, false }
	if value, found := object["intensity"]; found {
		result.intensity, ok = read_number(value)
		if !ok || result.intensity < 0 { return {}, false }
	}
	if value, found := object["range"]; found {
		result.range, ok = read_number(value)
		if !ok || result.range <= 0 { return {}, false }
	}
	if value, found := object["inner_angle"]; found {
		result.inner_angle, ok = read_number(value)
		if !ok || result.inner_angle <= 0 { return {}, false }
	}
	if value, found := object["outer_angle"]; found {
		result.outer_angle, ok = read_number(value)
		if !ok || result.outer_angle <= 0 { return {}, false }
	}
	if result.outer_angle < result.inner_angle { return {}, false }
	return result, true
}
