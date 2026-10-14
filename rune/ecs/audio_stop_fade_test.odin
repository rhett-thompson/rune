package ecs

import "core:encoding/json"
import "core:math"
import "core:testing"

audio_stop_fade_test_json :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}

@(test)
audio_stop_fade_defaults_and_json_validation :: proc(t: ^testing.T) {
	testing.expect(t, default_audio_player().fade_out_on_stop == 0, "existing players stop immediately by default")
	legacy, legacy_ok := audio_player_from_json(audio_stop_fade_test_json(`{"sound":"bell.wav"}`))
	testing.expect(t, legacy_ok && legacy.fade_out_on_stop == 0)
	for source in ([]string{
		`{"sound":"bell.wav","fade_out_on_stop":0}`,
		`{"sound":"bell.wav","fade_out_on_stop":0.5}`,
	}) {
		player, valid := audio_player_from_json(audio_stop_fade_test_json(source))
		testing.expect(t, valid && component_value_valid(player), source)
	}
	configured, configured_ok := audio_player_from_json(audio_stop_fade_test_json(`{"sound":"bell.wav","fade_out_on_stop":0.5}`))
	testing.expect(t, configured_ok && configured.fade_out_on_stop == 0.5)
	for source in ([]string{
		`{"sound":"bell.wav","fade_out_on_stop":-0.001}`,
		`{"sound":"bell.wav","fade_out_on_stop":1e100}`,
		`{"sound":"bell.wav","fade_out_on_stop":null}`,
		`{"sound":"bell.wav","fade_out_on_stop":true}`,
		`{"sound":"bell.wav","fade_out_on_stop":"0.5"}`,
	}) {
		_, accepted := audio_player_from_json(audio_stop_fade_test_json(source))
		testing.expect(t, !accepted, source)
	}
}

@(test)
audio_stop_fade_rejected_typed_edits_preserve_player :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	world := init(); defer destroy(&world)
	registry := init_registry(); defer destroy_registry(&registry)
	assert(register_builtin_components(&registry))
	entity := create_entity(&world)
	assert(add_component(&world, &registry, entity, "AudioPlayer", audio_stop_fade_test_json(`{"bell":{"sound":"bell.wav","fade_out_on_stop":0.5}}`)))
	configured, found := get_audio_player(&world, entity, "bell")
	assert(found)
	for bad in ([4]f32{-0.001, math.nan_f32(), math.inf_f32(1), math.inf_f32(-1)}) {
		candidate := configured
		candidate.fade_out_on_stop = bad
		testing.expect(t, !component_value_valid(candidate) && !set_audio_player(&world, entity, "bell", candidate), "typed stop fades must be finite and nonnegative")
		unchanged, present := get_audio_player(&world, entity, "bell")
		testing.expect(t, present && unchanged.fade_out_on_stop == 0.5, "a rejected edit preserves the previous duration")
	}
	configured.fade_out_on_stop = 0
	testing.expect(t, set_audio_player(&world, entity, "bell", configured), "zero restores immediate stopping")
}

@(test)
audio_stop_fade_runtime_json_roundtrip :: proc(t: ^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	world := init(); defer destroy(&world)
	registry := init_registry(); defer destroy_registry(&registry)
	assert(register_builtin_components(&registry))
	entity := create_entity(&world)
	assert(add_component(&world, &registry, entity, "AudioPlayer", audio_stop_fade_test_json(`{"bell":{"sound":"bell.wav","fade_out_on_stop":0.5}}`)))
	data, serialized := runtime_component_json(&world, entity, "AudioPlayer")
	testing.expect(t, serialized)
	copy := create_entity(&world)
	assert(add_component(&world, &registry, copy, "AudioPlayer", data))
	roundtrip, found := get_audio_player(&world, copy, "bell")
	testing.expect(t, found && roundtrip.fade_out_on_stop == 0.5, "runtime serialization retains the authored stop duration")
}
