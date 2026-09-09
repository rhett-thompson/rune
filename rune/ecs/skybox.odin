package ecs

import "core:encoding/json"
import "core:math"

Skybox_Mode :: enum {procedural, cubemap, atmospheric}
Skybox_Layout :: enum {auto_detect, line_vertical, line_horizontal, cross_three_by_four, cross_four_by_three, panorama}

// A background only; lighting remains controlled by the scene's lights.
Skybox :: struct {
	enabled: bool,
	mode: Skybox_Mode,
	texture: string,
	layout: Skybox_Layout,
	rotation: [3]f32, // Euler degrees, like Transform.rotation.
	energy: f32,
	resolution: i32, // Generated cubemap face size.
	procedural: Procedural_Sky,
	atmosphere: Atmospheric_Sky,
}

Atmospheric_Sky :: struct {
	sun: string, // Scene entity ID with a DirectionalLight.
	moon: string, // Optional DirectionalLight entity ID; empty disables the moon.
	moon_size: f32, // Angular diameter in degrees.
	night_color: [4]u8,
	night_energy: f32, // Artistic background fill, fading out at sunrise.
	rayleigh: f32,
	mie: f32,
	mie_anisotropy: f32,
	sun_size: f32, // Angular diameter in degrees.
	ground_color: [4]u8,
}

Procedural_Sky :: struct {
	sky_top_color: [4]u8,
	sky_horizon_color: [4]u8,
	sky_horizon_curve: f32,
	sky_energy: f32,
	ground_bottom_color: [4]u8,
	ground_horizon_color: [4]u8,
	ground_horizon_curve: f32,
	ground_energy: f32,
	sun_enabled: bool,
	sun_direction: [3]f32,
	sun_color: [4]u8,
	sun_size: f32, // Degrees.
	sun_curve: f32,
	sun_energy: f32,
}

default_skybox :: proc() -> Skybox {
	return {
		enabled = true, energy = 1, resolution = 256,
		atmosphere = {rayleigh = 1, mie = 1, mie_anisotropy = 0.8, sun_size = 0.53,
			moon_size = 0.52, night_color = {30,45,85,255}, night_energy = 0.3,
			ground_color = {45,53,59,255}},
		procedural = {
			sky_top_color = {98,116,140,255}, sky_horizon_color = {165,167,171,255},
			sky_horizon_curve = 0.15, sky_energy = 1,
			ground_bottom_color = {51,43,34,255}, ground_horizon_color = {165,167,171,255},
			ground_horizon_curve = 0.02, ground_energy = 1,
			sun_enabled = true,
			sun_direction = {-1,-1,-1}, sun_color = {255,255,255,255},
			sun_size = 1.5, sun_curve = 0.15, sun_energy = 1,
		},
	}
}

skybox_valid :: proc(value: Skybox) -> bool {
	if value.mode < .procedural || value.mode > .atmospheric || value.layout < .auto_detect || value.layout > .panorama {return false}
	if value.mode == .cubemap && len(value.texture) == 0 {return false}
	a := value.atmosphere
	if value.mode == .atmospheric && len(a.sun) == 0 {return false}
	for v in ([2]f32{a.rayleigh,a.mie}) {if !(v >= 0 && v <= 10) {return false}}
	if !(a.mie_anisotropy >= 0 && a.mie_anisotropy <= 0.95) {return false}
	if !(a.sun_size >= 0.1 && a.sun_size <= 20) {return false}
	if !(a.moon_size >= 0.1 && a.moon_size <= 20) || !finite_nonnegative(a.night_energy) {return false}
	if value.resolution < 16 || value.resolution > 2048 || (value.resolution & (value.resolution - 1)) != 0 {return false}
	if !finite_nonnegative(value.energy) {return false}
	for v in value.rotation {if math.is_nan(v) || math.is_inf(v) {return false}}
	p := value.procedural
	for v in p.sun_direction {if math.is_nan(v) || math.is_inf(v) {return false}}
	if p.sun_direction == ([3]f32{}) {return false}
	for v in ([3]f32{p.sky_energy, p.ground_energy, p.sun_energy}) {if !finite_nonnegative(v) {return false}}
	for v in ([3]f32{p.sky_horizon_curve, p.ground_horizon_curve, p.sun_curve}) {if !(v >= 0.01 && v <= 1) {return false}}
	return p.sun_size > 0 && p.sun_size <= 180
}

skybox_from_json :: proc(data: json.Value) -> (Skybox, bool) {
	if !post_processing_json_shape_valid(data, Skybox) {return {}, false}
	result := default_skybox()
	bytes, err := json.marshal(data, allocator = context.temp_allocator)
	if err != nil || json.unmarshal(bytes, &result, allocator = context.temp_allocator) != nil {return {}, false}
	return result, skybox_valid(result)
}

skybox_json :: proc(value: Skybox, allocator := context.temp_allocator) -> (json.Value, bool) {
	bytes, err := json.marshal(value, {use_enum_names = true}, allocator = context.temp_allocator)
	if err != nil {return {}, false}
	data: json.Value
	if json.unmarshal(bytes, &data, allocator = allocator) != nil {return {}, false}
	return data, true
}

get_skybox :: proc(world: ^World, entity: Entity) -> (Skybox, bool) {
	value, found := world.skyboxes[entity]
	return value, found
}

set_skybox :: proc(world: ^World, entity: Entity, value: Skybox) -> bool {
	if !has_component_data(world, entity, "Skybox") || !skybox_valid(value) {return false}
	commit_component_value(world, entity, "Skybox", &world.skyboxes, value)
	return true
}

// Active camera wins; otherwise the lowest enabled non-camera handle wins.
active_skybox :: proc(world: ^World, camera: Entity) -> (Skybox, bool) {
	if value, found := get_skybox(world, camera); found && is_enabled(world, camera) && value.enabled {return value, true}
	selected: Entity
	result: Skybox
	for entity, value in world.skyboxes {
		if !value.enabled || !is_enabled(world, entity) || has_component_data(world, entity, "Camera3D") {continue}
		if selected == 0 || entity < selected {selected, result = entity, value}
	}
	return result, selected != 0
}
