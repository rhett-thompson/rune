package ecs

import "core:encoding/json"
import "core:testing"

@(test)
audio_player_buffering_defaults_and_roundtrips :: proc(t: ^testing.T) {
	parse := proc(source: string) -> json.Value {
		value: json.Value
		assert(json.unmarshal(transmute([]u8)source, &value, allocator = context.temp_allocator) == nil)
		return value
	}
	automatic, valid := audio_player_from_json(parse(`{"sound":"clip.ogg"}`))
	testing.expect(t, valid && !automatic.buffered, "omitting buffered uses the format's default")
	_, valid = audio_player_from_json(parse(`{"sound":"clip.ogg","buffered":"true"}`))
	testing.expect(t, !valid, "buffered must be a boolean")

	registry := init_registry()
	defer destroy_registry(&registry)
	assert(register_builtin_components(&registry))
	world := init()
	defer destroy(&world)
	entity := create_entity(&world)
	assert(add_component(&world, &registry, entity, "AudioPlayer", parse(`{"effect":{"sound":"clip.ogg","buffered":true}}`)))
	data, serialized := runtime_component_json(&world, entity, "AudioPlayer")
	if !testing.expect(t, serialized, "serialize the buffered player") {return}
	copy := create_entity(&world)
	assert(add_component(&world, &registry, copy, "AudioPlayer", data))
	buffered, found := get_audio_player(&world, copy, "effect")
	testing.expect(t, found && buffered.buffered, "copying runtime JSON preserves the selected playback mode")
}
