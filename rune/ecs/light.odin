package ecs

import "core:encoding/json"
import "rune:shadows"

AmbientLight :: struct {
	color:     Color,
	intensity: f32,
}

DirectionalLight :: struct {
	shadows_disabled: bool,
	shadow_profile: string,
	shadow_overrides: shadows.Overrides,
	direction:         [3]f32,
	color:             Color,
	intensity:         f32,
	range:             f32,
	specular:          f32,
	shadows:           bool,
	shadow_softness:   f32,
	shadow_opacity:    f32,
	shadow_depth_bias: f32,
	shadow_slope_bias: f32,
}

PointLight :: struct {
	shadows_disabled: bool,
	shadow_profile: string,
	shadow_overrides: shadows.Overrides,
	color:             Color,
	intensity:         f32,
	range:             f32,
	specular:          f32,
	shadows:           bool,
	shadow_softness:   f32,
	shadow_opacity:    f32,
	shadow_depth_bias: f32,
	shadow_slope_bias: f32,
}

SpotLight :: struct {
	shadows_disabled: bool,
	shadow_profile: string,
	shadow_overrides: shadows.Overrides,
	direction:         [3]f32,
	color:             Color,
	intensity:         f32,
	range:             f32,
	inner_angle:       f32,
	outer_angle:       f32,
	specular:          f32,
	shadows:           bool,
	shadow_softness:   f32,
	shadow_opacity:    f32,
	shadow_depth_bias: f32,
	shadow_slope_bias: f32,
}

retain_light_strings :: proc(world: ^World, value: $T) -> T {
	result := value
	result.shadow_profile = retain_scene_string(world, value.shadow_profile)
	if mode, ok := value.shadow_overrides.update_mode.(string); ok {
		result.shadow_overrides.update_mode = retain_scene_string(world, mode)
	}
	return result
}

ambient_light_from_json :: proc(data: json.Value) -> (AmbientLight, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := AmbientLight {
		color     = {255, 255, 255, 255},
		intensity = 0.2,
	}
	if value, found := object["color"];
	   found && !read_color(value, &result.color) {return {}, false}
	if value, found := object["intensity"]; found {
		result.intensity, ok = read_number(value)
		if !ok || result.intensity < 0 {return {}, false}
	}
	return result, true
}

directional_light_from_json :: proc(data: json.Value) -> (DirectionalLight, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := DirectionalLight {
		direction      = {-0.35, -1, -0.45},
		color          = {255, 255, 255, 255},
		intensity      = 1,
		range          = 16,
		specular       = 1,
		shadow_opacity = 1,
	}
	if value, found := object["direction"];
	   found && !read_vector3(value, &result.direction) {return {}, false}
	if value, found := object["color"];
	   found && !read_color(value, &result.color) {return {}, false}
	if value, found := object["intensity"]; found {
		result.intensity, ok = read_number(value)
		if !ok || result.intensity < 0 {return {}, false}
	}
	if value, found := object["range"]; found {
		result.range, ok = read_number(value)
		if !ok || result.range <= 0 {return {}, false}
	}
	if !read_light_rendering_settings(
		object,
		&result.specular,
		&result.shadows,
		&result.shadow_softness,
		&result.shadow_opacity,
		&result.shadow_depth_bias,
		&result.shadow_slope_bias,
	) {
		return {}, false
	}
	if !read_shadow_profile(object,&result.shadow_profile,&result.shadow_overrides) {return {},false}
	if !read_shadow_gate(object,&result.shadows_disabled) {return {},false}
	return result, true
}

point_light_from_json :: proc(data: json.Value) -> (PointLight, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := PointLight {
		color          = {255, 255, 255, 255},
		intensity      = 1,
		range          = 5,
		specular       = 1,
		shadow_opacity = 1,
	}
	if value, found := object["color"];
	   found && !read_color(value, &result.color) {return {}, false}
	if value, found := object["intensity"]; found {
		result.intensity, ok = read_number(value)
		if !ok || result.intensity < 0 {return {}, false}
	}
	if value, found := object["range"]; found {
		result.range, ok = read_number(value)
		if !ok || result.range <= 0 {return {}, false}
	}
	if !read_light_rendering_settings(
		object,
		&result.specular,
		&result.shadows,
		&result.shadow_softness,
		&result.shadow_opacity,
		&result.shadow_depth_bias,
		&result.shadow_slope_bias,
	) {
		return {}, false
	}
	if !read_shadow_profile(object,&result.shadow_profile,&result.shadow_overrides) {return {},false}
	if !read_shadow_gate(object,&result.shadows_disabled) {return {},false}
	return result, true
}

spot_light_from_json :: proc(data: json.Value) -> (SpotLight, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := SpotLight {
		direction      = {0, -1, 0},
		color          = {255, 255, 255, 255},
		intensity      = 1,
		range          = 8,
		inner_angle    = 18,
		outer_angle    = 32,
		specular       = 1,
		shadow_opacity = 1,
	}
	if value, found := object["direction"];
	   found && !read_vector3(value, &result.direction) {return {}, false}
	if value, found := object["color"];
	   found && !read_color(value, &result.color) {return {}, false}
	if value, found := object["intensity"]; found {
		result.intensity, ok = read_number(value)
		if !ok || result.intensity < 0 {return {}, false}
	}
	if value, found := object["range"]; found {
		result.range, ok = read_number(value)
		if !ok || result.range <= 0 {return {}, false}
	}
	if value, found := object["inner_angle"]; found {
		result.inner_angle, ok = read_number(value)
		if !ok || result.inner_angle <= 0 {return {}, false}
	}
	if value, found := object["outer_angle"]; found {
		result.outer_angle, ok = read_number(value)
		if !ok || result.outer_angle <= 0 {return {}, false}
	}
	if result.outer_angle < result.inner_angle {return {}, false}
	if !read_light_rendering_settings(
		object,
		&result.specular,
		&result.shadows,
		&result.shadow_softness,
		&result.shadow_opacity,
		&result.shadow_depth_bias,
		&result.shadow_slope_bias,
	) {
		return {}, false
	}
	if !read_shadow_profile(object,&result.shadow_profile,&result.shadow_overrides) {return {},false}
	if !read_shadow_gate(object,&result.shadows_disabled) {return {},false}
	return result, true
}

read_shadow_gate :: proc(object: json.Object, disabled: ^bool) -> bool {
	if value,found:=object["shadows_disabled"]; found {
		b,ok:=value.(json.Boolean); if !ok {return false}; disabled^=b
	}
	return true
}

read_shadow_profile :: proc(object: json.Object, path: ^string, overrides: ^shadows.Overrides) -> bool {
	if value,found:=object["shadow_profile"]; found {
		p,ok:=value.(json.String); if !ok {return false}; path^=p
	}
	if value,found:=object["shadow_overrides"]; found {
		o,ok:=shadows.overrides_from_json(value); if !ok {return false}; overrides^=o
	}
	return true
}

read_light_rendering_settings :: proc(
	object: json.Object,
	specular: ^f32,
	shadows: ^bool,
	shadow_softness: ^f32,
	shadow_opacity: ^f32,
	shadow_depth_bias: ^f32,
	shadow_slope_bias: ^f32,
) -> bool {
	ok := true
	if value, found := object["specular"]; found {
		specular^, ok = read_number(value)
		if !ok || specular^ < 0 {return false}
	}
	if value, found := object["shadows"]; found {
		shadows^, ok = value.(json.Boolean)
		if !ok {return false}
	}
	if value, found := object["shadow_softness"]; found {
		shadow_softness^, ok = read_number(value)
		if !ok || shadow_softness^ < 0 {return false}
	}
	if value, found := object["shadow_opacity"]; found {
		shadow_opacity^, ok = read_number(value)
		if !ok || shadow_opacity^ < 0 {return false}
	}
	if value, found := object["shadow_depth_bias"]; found {
		shadow_depth_bias^, ok = read_number(value)
		if !ok || shadow_depth_bias^ < 0 {return false}
	}
	if value, found := object["shadow_slope_bias"]; found {
		shadow_slope_bias^, ok = read_number(value)
		if !ok || shadow_slope_bias^ < 0 {return false}
	}
	return true
}
