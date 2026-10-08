package ecs

import "core:encoding/json"
import "core:math"
import "core:testing"

light_fog_test_json :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator=context.temp_allocator) == nil)
	return value
}

light_fog_test_case :: proc(t: ^testing.T, name: string, defaults: $T) {
	testing.expect(t, defaults.fog_energy == nil && (defaults.fog_energy.(f32) or_else 1) == 1, "omitted fog energy preserves the native multiplier")
	r := init_registry()
	defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	w := init()
	defer destroy(&w)
	literal := T{}
	literal.range = defaults.range
	when T == SpotLight {
		literal.inner_angle = defaults.inner_angle
		literal.outer_angle = defaults.outer_angle
	}
	testing.expect(t, literal.fog_energy == nil && (literal.fog_energy.(f32) or_else 1) == 1,
		"existing typed light literals retain the native multiplier when fog energy is omitted")
	typed := create_entity(&w)
	assert(add(&w, &r, typed, literal))
	typed_data, typed_serialized := runtime_component_json(&w, typed, name)
	testing.expect(t, typed_serialized)
	typed_copy := create_entity(&w)
	assert(add_component(&w, &r, typed_copy, name, typed_data))
	default_copy, _ := get(&w, typed_copy, T)
	testing.expect(t, default_copy.fog_energy == nil && (default_copy.fog_energy.(f32) or_else 1) == 1,
		"nullable reflection snapshots must retain the default for existing typed lights")
	e := create_entity(&w)
	assert(add_component(&w, &r, e, name, light_fog_test_json(`{"intensity":0.25,"fog_energy":12,"shadow_overrides":{"opacity":0.6}}`)))
	current, found := get(&w, e, T)
	testing.expect(t, found && (current.fog_energy.(f32) or_else 1) == 12 && current.intensity == 0.25)
	data, serialized := runtime_component_json(&w, e, name)
	testing.expect(t, serialized)
	copy := create_entity(&w)
	assert(add_component(&w, &r, copy, name, data))
	copy_value, _ := get(&w, copy, T)
	testing.expect(t, copy_value == current, "fog energy and existing settings roundtrip together")
	assert(set_runtime_field(&w, &r, e, name, "fog_energy", json.Integer(0)))
	current, _ = get(&w, e, T)
	testing.expect(t, (current.fog_energy.(f32) or_else 1) == 0 && current.intensity == 0.25, "explicit zero changes only fog illumination")
	for bad in ([]string{
		`{"fog_energy":-0.01}`, `{"fog_energy":true}`,
		`{"fog_energy":"bright"}`, `{"fog_energy":1e100}`,
	}) {
		testing.expect(t, !add_component(&w, &r, e, name, light_fog_test_json(bad)), bad)
		unchanged, _ := get(&w, e, T)
		testing.expect(t, unchanged == current, "invalid JSON preserves the current light")
	}
	for bad in ([4]f32{-1, math.nan_f32(), math.inf_f32(1), math.inf_f32(-1)}) {
		invalid := current
		invalid.fog_energy = bad
		testing.expect(t, !set(&w, e, invalid) && !add(&w, &r, e, invalid), "typed light writes reject invalid fog multipliers")
		testing.expect(t, !set_runtime_field(&w, &r, e, name, "fog_energy", json.Float(f64(bad))))
		unchanged, _ := get(&w, e, T)
		testing.expect(t, unchanged == current, "rejected runtime edits preserve all light settings")
	}
	assert(set_runtime_field(&w, &r, e, name, "specular", json.Float(0.5)))
	current, _ = get(&w, e, T)
	testing.expect(t, (current.fog_energy.(f32) or_else 1) == 0 && current.specular == 0.5, "other edits preserve explicit zero fog energy")
	assert(set_runtime_field(&w, &r, e, name, "fog_energy", nil))
	current, _ = get(&w, e, T)
	testing.expect(t, current.fog_energy == nil && (current.fog_energy.(f32) or_else 1) == 1 && current.intensity == 0.25 && current.specular == 0.5,
		"null restores the native fog multiplier while retaining other light settings")
}

@(test)
directional_light_fog_energy_data :: proc(t: ^testing.T) {
	defaults, ok := directional_light_from_json(light_fog_test_json("{}"))
	testing.expect(t, ok)
	light_fog_test_case(t, "DirectionalLight", defaults)
}

@(test)
point_light_fog_energy_data :: proc(t: ^testing.T) {
	defaults, ok := point_light_from_json(light_fog_test_json("{}"))
	testing.expect(t, ok)
	light_fog_test_case(t, "PointLight", defaults)
}

@(test)
spot_light_fog_energy_data :: proc(t: ^testing.T) {
	defaults, ok := spot_light_from_json(light_fog_test_json("{}"))
	testing.expect(t, ok)
	light_fog_test_case(t, "SpotLight", defaults)
}
