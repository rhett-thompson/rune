package ecs

import "core:encoding/json"

// AudioListener identifies the entity used as the scene's audio reference
// point. It normally shares an entity with the active camera, but that is a
// scene convention rather than an ECS restriction.
AudioListener :: struct {
	active: bool,
}

// AudioPlayer describes audio emitted by an entity. Music formats such as MP3,
// OGG, and FLAC stream automatically; short clips remain buffered sounds.
AudioPlayer :: struct {
	sound:         string,
	volume:        f32,
	pitch:         f32,
	random_volume: f32,
	random_pitch:  f32,
	max_voices:    i32,
	looping:       bool,
	spatial:       bool,
	min_distance:  f32,
	max_distance:  f32,
	play_on_start: bool,
}

default_audio_listener :: proc() -> AudioListener {
	return AudioListener{active = true}
}

default_audio_player :: proc() -> AudioPlayer {
	return AudioPlayer{volume = 1, pitch = 1, max_voices = 4, min_distance = 1, max_distance = 20}
}

audio_listener_from_json :: proc(data: json.Value) -> (AudioListener, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }

	result := default_audio_listener()
	if value, found := object["active"]; found {
		result.active, ok = value.(json.Boolean)
		if !ok { return {}, false }
	}
	return result, true
}

audio_player_from_json :: proc(data: json.Value) -> (AudioPlayer, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }

	result := default_audio_player()
	value, found := object["sound"]
	if !found { return {}, false }
	result.sound, ok = value.(json.String)
	if !ok || len(result.sound) == 0 { return {}, false }
	if value, found := object["volume"]; found {
		result.volume, ok = read_number(value)
		if !ok || result.volume < 0 { return {}, false }
	}
	if value, found := object["pitch"]; found {
		result.pitch, ok = read_number(value)
		if !ok || result.pitch <= 0 { return {}, false }
	}
	if value, found := object["random_volume"]; found {
		result.random_volume, ok = read_number(value)
		if !ok || result.random_volume < 0 { return {}, false }
	}
	if value, found := object["random_pitch"]; found {
		result.random_pitch, ok = read_number(value)
		if !ok || result.random_pitch < 0 { return {}, false }
	}
	if value, found := object["max_voices"]; found {
		number, number_ok := read_number(value)
		if !number_ok || number < 1 || number != f32(i32(number)) { return {}, false }
		result.max_voices = i32(number)
	}
	if value, found := object["looping"]; found { result.looping, ok = value.(json.Boolean); if !ok { return {}, false } }
	if value, found := object["spatial"]; found { result.spatial, ok = value.(json.Boolean); if !ok { return {}, false } }
	if value, found := object["min_distance"]; found {
		result.min_distance, ok = read_number(value)
		if !ok || result.min_distance < 0 { return {}, false }
	}
	if value, found := object["max_distance"]; found {
		result.max_distance, ok = read_number(value)
		if !ok || result.max_distance < result.min_distance { return {}, false }
	}
	if value, found := object["play_on_start"]; found { result.play_on_start, ok = value.(json.Boolean); if !ok { return {}, false } }
	return result, true
}
