package ecs

import "core:encoding/json"
import "core:math"
import "core:reflect"

// PostProcessing is a complete 3D profile. An enabled active-camera profile
// wins; otherwise the lowest-handle enabled non-camera profile is used.
// The component does not require Transform. No spatial volumes or blending.
PostProcessing :: struct {
	enabled: bool,
	anti_aliasing: Post_Anti_Aliasing,
	bloom: Post_Bloom,
	film_grain: Post_Film_Grain,
	tonemap: Post_Tonemap,
	color: Post_Color,
	ssao: Post_SSAO,
	ssil: Post_SSIL,
	ssgi: Post_SSGI,
	ssr: Post_SSR,
	fog: Post_Fog,
	volumetric_fog: Post_Volumetric_Fog,
	height_fog: Post_Height_Fog,
	upper_height_fog: Post_Height_Fog,
	light_shafts: Post_Light_Shafts,
	dof: Post_DoF,
	auto_exposure: Post_Auto_Exposure,
}

Post_Bloom_Mode :: enum {disabled, mix, additive, screen}
Post_Tonemap_Mode :: enum {linear, reinhard, filmic, aces, agx}
Post_Fog_Mode :: enum {disabled, linear, exp2, exp}
Post_Anti_Aliasing :: enum {disabled, fxaa, smaa}

Post_Bloom :: struct {
	mode: Post_Bloom_Mode,
	levels: f32,
	intensity: f32,
	threshold: f32,
	soft_threshold: f32,
	filter_radius: f32,
}

// Monochrome display-space noise after tone mapping and anti-aliasing.
// Size is in rendered pixels; speed is pattern changes/second (zero freezes it).
Post_Film_Grain :: struct {
	enabled: bool,
	intensity, size, speed: f32,
}

Post_Tonemap :: struct {
	mode: Post_Tonemap_Mode,
	exposure: f32,
	white: f32,
}

Post_Color :: struct {
	brightness: f32,
	contrast: f32,
	saturation: f32,
}

Post_SSAO :: struct {
	enabled: bool,
	sample_count: i32,
	intensity: f32,
	power: f32,
	max_radius: f32,
	radius: f32,
	bias: f32,
}

Post_SSIL :: struct {
	enabled: bool,
	sample_count: i32,
	gi_intensity: f32,
	ao_intensity: f32,
	ao_power: f32,
	max_radius: f32,
	radius: f32,
	bias: f32,
}

Post_SSGI :: struct {
	enabled: bool,
	slice_count: i32,
	edge_fade: f32,
	distance_falloff: f32,
	normal_rejection: f32,
	intensity: f32,
	denoise_steps: i32,
}

Post_SSR :: struct {
	enabled: bool,
	max_ray_steps: i32,
	binary_steps: i32,
	step_size: f32,
	thickness: f32,
	max_distance: f32,
	edge_fade: f32,
}

Post_Fog :: struct {
	mode: Post_Fog_Mode,
	color: [4]u8,
	start: f32,
	end: f32,
	density: f32,
	sky_affect: f32,
}

// Native homogeneous fog scattering from scene lights. This is independent
// of distance fog, height fog, and screen-space light shafts.
Post_Volumetric_Fog :: struct {
	enabled: bool,
	scattering_density, absorption_density: f32,
	scattering_color: [4]u8,
	anisotropy: f32,
	emission_color: [4]u8,
	emission_energy, sky_affect: f32,
	length, step_size: f32,
}

// Density at world Y = base_height. height_fog decreases above it;
// upper_height_fog increases above it. Both use nonnegative falloff.
// Zero falloff is uniform fog; zero density disables extinction.
Post_Height_Fog :: struct {
	enabled: bool,
	color: [4]u8,
	base_height: f32,
	density: f32,
	falloff: f32,
	sky_distance: f32,
}

// Screen-space radial scattering from a finite source entity. Radius is in
// screen heights; source_radius is in world units and includes the emitter.
Post_Light_Shafts :: struct {
	enabled: bool,
	source: string,
	color: [4]u8,
	intensity, radius, source_radius: f32,
	samples: i32,
}

Post_DoF :: struct {
	enabled: bool,
	focus_point: f32,
	focus_scale: f32,
	near_scale: f32,
	max_blur_size: f32,
}

Post_Auto_Exposure :: struct {
	enabled: bool,
	min_ev: f32,
	max_ev: f32,
	exposure_compensation: f32,
	adaptation_to_bright: f32,
	adaptation_to_dark: f32,
}

default_post_processing :: proc() -> PostProcessing {
	return {
		enabled = true,
		anti_aliasing = .fxaa,
		bloom = {
			mode = .disabled,
			levels = 0.5,
			intensity = 0.05,
			threshold = 0,
			soft_threshold = 0.5,
			filter_radius = 1,
		},
		tonemap = {
			mode = .linear,
			exposure = 1,
			white = 1,
		},
		film_grain = {intensity=0.02,size=1,speed=24},
		color = {
			brightness = 1,
			contrast = 1,
			saturation = 1,
		},
		ssao = {
			enabled = false,
			sample_count = 16,
			intensity = 1,
			power = 1,
			max_radius = 0.2,
			radius = 1,
			bias = 0.03,
		},
		ssil = {
			enabled = false,
			sample_count = 16,
			gi_intensity = 1,
			ao_intensity = 1,
			ao_power = 1,
			max_radius = 0.2,
			radius = 4,
			bias = 0.03,
		},
		ssgi = {
			enabled = false,
			slice_count = 4,
			edge_fade = 0.1,
			distance_falloff = 1,
			normal_rejection = 0,
			intensity = 1,
			denoise_steps = 4,
		},
		ssr = {
			enabled = false,
			max_ray_steps = 32,
			binary_steps = 4,
			step_size = 0.125,
			thickness = 0.2,
			max_distance = 4,
			edge_fade = 0.25,
		},
		fog = {
			mode = .disabled,
			color = {255,255,255,255},
			start = 1,
			end = 50,
			density = 0.05,
			sky_affect = 0.5,
		},
		volumetric_fog = {
			scattering_density = 0.01,
			absorption_density = 0.03,
			scattering_color = {255,255,255,255},
			anisotropy = 0.5,
			emission_color = {255,255,255,255},
			emission_energy = 0,
			sky_affect = 0.5,
			length = 50,
			step_size = 1,
		},
		height_fog = {
			color = {255,255,255,255},
			density = 0.01,
			falloff = 0.1,
			sky_distance = 1000,
		},
		upper_height_fog = {
			color = {255,255,255,255},
			density = 0.01,
			falloff = 0.1,
			sky_distance = 1000,
		},
		light_shafts = {color={255,240,202,255},intensity=0.5,radius=0.7,source_radius=1,samples=32},
		dof = {
			enabled = false,
			focus_point = 10,
			focus_scale = 1,
			near_scale = 1,
			max_blur_size = 20,
		},
		auto_exposure = {
			enabled = false,
			min_ev = -1,
			max_ev = 1,
			exposure_compensation = 0,
			adaptation_to_bright = 0.5,
			adaptation_to_dark = 1,
		},
	}
}

// Strict shape checking includes nulls, enum strings, integer counts and colors.
// Missing fields retain defaults, including inside partially authored groups.
// Also used by Skybox, which has the same strict nested data contract.
post_processing_json_shape_valid :: proc(value: json.Value, tid: typeid) -> bool {
	ti := reflect.type_info_base(type_info_of(tid))
	#partial switch info in ti.variant {
	case reflect.Type_Info_Struct:
		object, ok := value.(json.Object)
		if !ok {return false}
		for key, child in object {
			field_type, found := json_struct_field_type(tid, key)
			if !found || !post_processing_json_shape_valid(child, field_type) {return false}
		}
		return true
	case reflect.Type_Info_Array:
		array, ok := value.(json.Array)
		if !ok || len(array) != info.count {return false}
		for child in array {if !post_processing_json_shape_valid(child, info.elem.id) {return false}}
		return true
	case reflect.Type_Info_Enum:
		name, ok := value.(json.String)
		if !ok {return false}
		for item in info.names {if string(name) == item {return true}}
		return false
	case reflect.Type_Info_String:
		_, ok := value.(json.String)
		return ok
	case reflect.Type_Info_Boolean:
		_, ok := value.(json.Boolean)
		return ok
	case reflect.Type_Info_Integer:
		number, ok := value.(json.Integer)
		if !ok {return false}
		if tid == u8 {return number >= 0 && number <= 255}
		return number >= -2147483648 && number <= 2147483647
	case reflect.Type_Info_Float:
		number, ok := read_number(value)
		return ok && !math.is_nan(number) && !math.is_inf(number)
	}
	return false
}

post_processing_from_json :: proc(data: json.Value) -> (PostProcessing, bool) {
	if !post_processing_json_shape_valid(data, PostProcessing) {return {}, false}
	result := default_post_processing()
	bytes, err := json.marshal(data, allocator = context.temp_allocator)
	if err != nil || json.unmarshal(bytes, &result, allocator = context.temp_allocator) != nil {return {}, false}
	return result, post_processing_valid(result)
}

post_processing_valid :: proc(value: PostProcessing) -> bool {
	if value.anti_aliasing < .disabled || value.anti_aliasing > .smaa {return false}
	if value.bloom.mode < .disabled || value.bloom.mode > .screen {return false}
	if math.is_nan(value.bloom.levels) || math.is_inf(value.bloom.levels) || value.bloom.levels < 0 || value.bloom.levels > 1 {return false}
	if math.is_nan(value.bloom.intensity) || math.is_inf(value.bloom.intensity) || value.bloom.intensity < 0 {return false}
	if math.is_nan(value.bloom.threshold) || math.is_inf(value.bloom.threshold) || value.bloom.threshold < 0 {return false}
	if math.is_nan(value.bloom.soft_threshold) || math.is_inf(value.bloom.soft_threshold) || value.bloom.soft_threshold < 0 || value.bloom.soft_threshold > 1 {return false}
	if math.is_nan(value.bloom.filter_radius) || math.is_inf(value.bloom.filter_radius) || value.bloom.filter_radius < 0 {return false}
	if value.tonemap.mode < .linear || value.tonemap.mode > .agx {return false}
	if math.is_nan(value.tonemap.exposure) || math.is_inf(value.tonemap.exposure) || value.tonemap.exposure < 0 {return false}
	if math.is_nan(value.tonemap.white) || math.is_inf(value.tonemap.white) || value.tonemap.white <= 0 {return false}
	if math.is_nan(value.color.brightness) || math.is_inf(value.color.brightness) || value.color.brightness < 0 {return false}
	if math.is_nan(value.color.contrast) || math.is_inf(value.color.contrast) || value.color.contrast < 0 {return false}
	if math.is_nan(value.color.saturation) || math.is_inf(value.color.saturation) || value.color.saturation < 0 {return false}
	if value.ssao.sample_count < 1 || value.ssao.sample_count > 64 {return false}
	if math.is_nan(value.ssao.intensity) || math.is_inf(value.ssao.intensity) || value.ssao.intensity < 0 {return false}
	if math.is_nan(value.ssao.power) || math.is_inf(value.ssao.power) || value.ssao.power <= 0 {return false}
	if math.is_nan(value.ssao.max_radius) || math.is_inf(value.ssao.max_radius) || value.ssao.max_radius <= 0 || value.ssao.max_radius > 1 {return false}
	if math.is_nan(value.ssao.radius) || math.is_inf(value.ssao.radius) || value.ssao.radius <= 0 {return false}
	if math.is_nan(value.ssao.bias) || math.is_inf(value.ssao.bias) || value.ssao.bias < 0 {return false}
	if value.ssil.sample_count < 1 || value.ssil.sample_count > 64 {return false}
	if math.is_nan(value.ssil.gi_intensity) || math.is_inf(value.ssil.gi_intensity) || value.ssil.gi_intensity < 0 {return false}
	if math.is_nan(value.ssil.ao_intensity) || math.is_inf(value.ssil.ao_intensity) || value.ssil.ao_intensity < 0 {return false}
	if math.is_nan(value.ssil.ao_power) || math.is_inf(value.ssil.ao_power) || value.ssil.ao_power <= 0 {return false}
	if math.is_nan(value.ssil.max_radius) || math.is_inf(value.ssil.max_radius) || value.ssil.max_radius <= 0 || value.ssil.max_radius > 1 {return false}
	if math.is_nan(value.ssil.radius) || math.is_inf(value.ssil.radius) || value.ssil.radius <= 0 {return false}
	if math.is_nan(value.ssil.bias) || math.is_inf(value.ssil.bias) || value.ssil.bias < 0 {return false}
	if value.ssgi.slice_count < 1 || value.ssgi.slice_count > 32 {return false}
	if math.is_nan(value.ssgi.edge_fade) || math.is_inf(value.ssgi.edge_fade) || value.ssgi.edge_fade < 0 || value.ssgi.edge_fade > 1 {return false}
	if math.is_nan(value.ssgi.distance_falloff) || math.is_inf(value.ssgi.distance_falloff) || value.ssgi.distance_falloff < 0 {return false}
	if math.is_nan(value.ssgi.normal_rejection) || math.is_inf(value.ssgi.normal_rejection) || value.ssgi.normal_rejection < 0 || value.ssgi.normal_rejection > 1 {return false}
	if math.is_nan(value.ssgi.intensity) || math.is_inf(value.ssgi.intensity) || value.ssgi.intensity < 0 {return false}
	if value.ssgi.denoise_steps < 0 || value.ssgi.denoise_steps > 8 {return false}
	if value.ssr.max_ray_steps < 1 || value.ssr.max_ray_steps > 256 {return false}
	if value.ssr.binary_steps < 0 || value.ssr.binary_steps > 32 {return false}
	if math.is_nan(value.ssr.step_size) || math.is_inf(value.ssr.step_size) || value.ssr.step_size <= 0 {return false}
	if math.is_nan(value.ssr.thickness) || math.is_inf(value.ssr.thickness) || value.ssr.thickness <= 0 {return false}
	if math.is_nan(value.ssr.max_distance) || math.is_inf(value.ssr.max_distance) || value.ssr.max_distance <= 0 {return false}
	if math.is_nan(value.ssr.edge_fade) || math.is_inf(value.ssr.edge_fade) || value.ssr.edge_fade < 0 || value.ssr.edge_fade > 1 {return false}
	if value.fog.mode < .disabled || value.fog.mode > .exp {return false}
	if math.is_nan(value.fog.start) || math.is_inf(value.fog.start) || value.fog.start < 0 {return false}
	if math.is_nan(value.fog.end) || math.is_inf(value.fog.end) || value.fog.end < 0 {return false}
	if math.is_nan(value.fog.density) || math.is_inf(value.fog.density) || value.fog.density < 0 {return false}
	if math.is_nan(value.fog.sky_affect) || math.is_inf(value.fog.sky_affect) || value.fog.sky_affect < 0 || value.fog.sky_affect > 1 {return false}
	volumetric := value.volumetric_fog
	if !finite_nonnegative(volumetric.scattering_density) || !finite_nonnegative(volumetric.absorption_density) {return false}
	if !(volumetric.anisotropy > -1 && volumetric.anisotropy < 1) {return false}
	if !finite_nonnegative(volumetric.emission_energy) {return false}
	if !finite_nonnegative(volumetric.sky_affect) || volumetric.sky_affect > 1 {return false}
	if !finite_nonnegative(volumetric.length) || volumetric.length <= 0 {return false}
	if !finite_nonnegative(volumetric.step_size) || volumetric.step_size <= 0 {return false}
	// r3d ray marches until length without an independent iteration cap.
	if volumetric.length / volumetric.step_size > 1024 {return false}
	for fog in ([2]Post_Height_Fog{value.height_fog,value.upper_height_fog}) {
		if math.is_nan(fog.base_height) || math.is_inf(fog.base_height) {return false}
		if !finite_nonnegative(fog.density) || !finite_nonnegative(fog.falloff) {return false}
		if math.is_nan(fog.sky_distance) || math.is_inf(fog.sky_distance) || fog.sky_distance <= 0 {return false}
	}
	shafts:=value.light_shafts
	grain:=value.film_grain
	if !finite_nonnegative(grain.intensity) || grain.intensity>1 {return false}
	if !finite_nonnegative(grain.size) || grain.size<1 || grain.size>8 {return false}
	if !finite_nonnegative(grain.speed) || grain.speed>60 {return false}
	if shafts.enabled && shafts.source=="" {return false}
	if !finite_nonnegative(shafts.intensity) || shafts.intensity>10 {return false}
	if !finite_nonnegative(shafts.radius) || shafts.radius<=0 || shafts.radius>2 {return false}
	if !finite_nonnegative(shafts.source_radius) || shafts.source_radius<=0 {return false}
	if shafts.samples<8 || shafts.samples>64 {return false}
	if math.is_nan(value.dof.focus_point) || math.is_inf(value.dof.focus_point) || value.dof.focus_point <= 0 {return false}
	if math.is_nan(value.dof.focus_scale) || math.is_inf(value.dof.focus_scale) || value.dof.focus_scale <= 0 {return false}
	if math.is_nan(value.dof.near_scale) || math.is_inf(value.dof.near_scale) || value.dof.near_scale < 0 {return false}
	if math.is_nan(value.dof.max_blur_size) || math.is_inf(value.dof.max_blur_size) || value.dof.max_blur_size < 0 || value.dof.max_blur_size > 64 {return false}
	if math.is_nan(value.auto_exposure.min_ev) || math.is_inf(value.auto_exposure.min_ev) || value.auto_exposure.min_ev < -32 || value.auto_exposure.min_ev > 32 {return false}
	if math.is_nan(value.auto_exposure.max_ev) || math.is_inf(value.auto_exposure.max_ev) || value.auto_exposure.max_ev < -32 || value.auto_exposure.max_ev > 32 {return false}
	if math.is_nan(value.auto_exposure.exposure_compensation) || math.is_inf(value.auto_exposure.exposure_compensation) || value.auto_exposure.exposure_compensation < -32 || value.auto_exposure.exposure_compensation > 32 {return false}
	if math.is_nan(value.auto_exposure.adaptation_to_bright) || math.is_inf(value.auto_exposure.adaptation_to_bright) || value.auto_exposure.adaptation_to_bright <= 0 {return false}
	if math.is_nan(value.auto_exposure.adaptation_to_dark) || math.is_inf(value.auto_exposure.adaptation_to_dark) || value.auto_exposure.adaptation_to_dark <= 0 {return false}
	return value.fog.end > value.fog.start && value.auto_exposure.max_ev >= value.auto_exposure.min_ev
}

post_processing_json :: proc(value: PostProcessing, allocator := context.temp_allocator) -> (json.Value, bool) {
	bytes, err := json.marshal(value, {use_enum_names = true}, allocator = context.temp_allocator)
	if err != nil {return {}, false}
	data: json.Value
	if json.unmarshal(bytes, &data, allocator = allocator) != nil {return {}, false}
	return data, true
}

get_post_processing :: proc(world: ^World, entity: Entity) -> (PostProcessing, bool) {
	value, found := world.post_processing[entity]
	return value, found
}

set_post_processing :: proc(world: ^World, entity: Entity, value: PostProcessing) -> bool {
	if !has_component_data(world, entity, "PostProcessing") || !post_processing_valid(value) {return false}
	commit_component_value(world, entity, "PostProcessing", &world.post_processing, value)
	return true
}

// Return the selected owner so tools can edit the same profile the renderer uses.
active_post_processing_entity :: proc(world: ^World, camera: Entity) -> (Entity, bool) {
	if value, found := get_post_processing(world, camera); found && is_enabled(world, camera) && value.enabled {
		return camera, true
	}
	selected: Entity
	for entity, value in world.post_processing {
		if !value.enabled || !is_enabled(world, entity) || has_component_data(world, entity, "Camera3D") {continue}
		if selected == 0 || entity < selected {selected = entity}
	}
	return selected, selected != 0
}

active_post_processing :: proc(world: ^World, camera: Entity) -> (PostProcessing, bool) {
	entity, found := active_post_processing_entity(world, camera)
	if !found {return {}, false}
	return get_post_processing(world, entity)
}
