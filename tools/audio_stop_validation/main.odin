package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "rune:audio"
import "rune:ecs"
import rl "vendor:raylib"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}

assert_volume :: proc(system: ^audio.Audio_System, entity: ecs.Entity, name: string, expected: f32) {
	key := ecs.Component_Instance{entity = entity, name = name}
	assert(abs(system.instances[key].volume - expected) < 0.0001,
		fmt.tprintf("%s expected volume %g, got %g", name, expected, system.instances[key].volume))
}

configuration_test :: proc(registry: ^ecs.Component_Registry) {
	assert(ecs.default_audio_player().fade_out_on_stop == 0, "existing audio stops immediately by default")
	for source in ([]string{
		`{"sound":"bell.wav"}`,
		`{"sound":"bell.wav","fade_out_on_stop":0}`,
		`{"sound":"bell.wav","fade_out_on_stop":0.5}`,
	}) {
		_, valid := ecs.audio_player_from_json(parse(source))
		assert(valid, source)
	}
	for source in ([]string{
		`{"sound":"bell.wav","fade_out_on_stop":-0.5}`,
		`{"sound":"bell.wav","fade_out_on_stop":"0.5"}`,
	}) {
		_, valid := ecs.audio_player_from_json(parse(source))
		assert(!valid, source)
	}
	world := ecs.init()
	defer ecs.destroy(&world)
	entity := ecs.create_entity(&world)
	assert(ecs.add_component(&world, registry, entity, "AudioPlayer", parse(
		`{"loop":{"sound":"bell.wav","fade_out_on_stop":0.5}}`)))
	player, found := ecs.get_audio_player(&world, entity, "loop")
	assert(found && player.fade_out_on_stop == 0.5)
	for duration in ([3]f32{-0.5, math.nan_f32(), math.inf_f32(1)}) {
		player.fade_out_on_stop = duration
		assert(!ecs.set_audio_player(&world, entity, "loop", player), "duration must be finite and nonnegative")
	}
	assert(ecs.set_runtime_field(&world, registry, entity, "AudioPlayer", "loop.fade_out_on_stop", json.Float(0.25)))
	player, found = ecs.get_audio_player(&world, entity, "loop")
	assert(found && player.fade_out_on_stop == 0.25, "duration is editable through component runtime fields")
}

loop_test :: proc(system: ^audio.Audio_System, world: ^ecs.World, entity: ecs.Entity) {
	assert(audio.play(system, world, entity, "loop"))
	assert_volume(system, entity, "loop", 0.8)
	assert(audio.stop(system, entity, "loop"))
	assert(audio.is_stopping(system, entity, "loop"))
	assert(audio.is_playing(system, entity, "loop"), "configured stop fades before stopping playback")
	audio.update(system, world, 0.25)
	assert_volume(system, entity, "loop", 0.4)
	assert(audio.stop(system, entity, "loop"), "repeat stops remain successful")
	audio.update(system, world, 0.25)
	assert(!audio.is_playing(system, entity, "loop"), "repeat stop must not restart the envelope")
	assert(!audio.is_stopping(system, entity, "loop"))
	for _ in 0..<3 {audio.update(system, world, 1)}
	assert(!audio.is_playing(system, entity, "loop"), "autoplay must remain stopped after an explicit stop")

	assert(audio.play(system, world, entity, "loop"))
	assert(audio.stop(system, entity, "loop"))
	audio.update(system, world, 0.25)
	assert_volume(system, entity, "loop", 0.4)
	assert(audio.play(system, world, entity, "loop"))
	assert(!audio.is_stopping(system, entity, "loop"), "play clears the stop status")
	assert_volume(system, entity, "loop", 0.8)
	audio.update(system, world, 0.5)
	assert(audio.is_playing(system, entity, "loop"), "play cancels pending stop")
	assert_volume(system, entity, "loop", 0.8)
	assert(audio.stop(system, entity, "loop", 0))
	assert(!audio.is_playing(system, entity, "loop"), "zero override stops immediately")
	audio.update(system, world, 1)
	assert(!audio.is_playing(system, entity, "loop"))

	assert(audio.play(system, world, entity, "loop"))
	assert(audio.stop(system, entity, "loop", 1))
	audio.update(system, world, 0.5)
	assert_volume(system, entity, "loop", 0.4)
	assert(audio.is_playing(system, entity, "loop"), "override controls stop duration")
	audio.update(system, world, 0.5)
	assert(!audio.is_playing(system, entity, "loop"))
	assert(audio.play(system, world, entity, "loop"))
	for duration in ([3]f32{-2, math.nan_f32(), math.inf_f32(1)}) {
		assert(!audio.stop(system, entity, "loop", duration), "invalid override must leave playback running")
		assert(audio.is_playing(system, entity, "loop"))
	}
	assert(audio.stop(system, entity, "loop", 0))
	player, _ := ecs.get_audio_player(world, entity, "loop")
	player.fade_out_on_stop = 0
	assert(ecs.set_audio_player(world, entity, "loop", player))
	assert(audio.play(system, world, entity, "loop"))
	assert(audio.stop(system, entity, "loop"))
	assert(!audio.is_playing(system, entity, "loop"), "configured zero retains immediate stop behavior")
	player.fade_out_on_stop = 0.5
	assert(ecs.set_audio_player(world, entity, "loop", player))
}

voice_test :: proc(system: ^audio.Audio_System, world: ^ecs.World, entity: ecs.Entity) {
	for _ in 0..<3 {assert(audio.play(system, world, entity, "oneshot"))}
	key := ecs.Component_Instance{entity = entity, name = "oneshot"}
	assert(len(system.instances[key].voices) == 3)
	for voice in system.instances[key].voices {assert(rl.IsSoundPlaying(voice.sound))}
	assert(audio.stop(system, entity, "oneshot"))
	audio.update(system, world, 0.25)
	assert(audio.is_playing(system, entity, "oneshot"), "one-shot aliases continue during fade")
	assert_volume(system, entity, "oneshot", 0.3)
	audio.update(system, world, 0.25)
	for voice in system.instances[key].voices {
		assert(!rl.IsSoundPlaying(voice.sound), "stop completion must stop every alias")
	}
	assert(!audio.is_playing(system, entity, "oneshot"))
	assert(audio.play(system, world, entity, "oneshot"))
	assert(audio.stop(system, entity, "oneshot"))
	audio.update(system, world, 0.25)
	assert(audio.play(system, world, entity, "oneshot"))
	assert_volume(system, entity, "oneshot", 0.6)
	audio.update(system, world, 0.5)
	assert(audio.is_playing(system, entity, "oneshot"), "new one-shot cancels an earlier pending stop")
	assert_volume(system, entity, "oneshot", 0.6)
	assert(audio.stop(system, entity, "oneshot", 0))
}

stream_test :: proc(system: ^audio.Audio_System, world: ^ecs.World, entity: ecs.Entity) {
	assert(audio.play(system, world, entity, "stream"))
	key := ecs.Component_Instance{entity = entity, name = "stream"}
	assert(system.instances[key].streaming)
	assert(audio.stop(system, entity, "stream"))
	audio.update(system, world, 0.25)
	assert(audio.is_playing(system, entity, "stream"), "MP3 continues while fading")
	assert_volume(system, entity, "stream", 0.35)
	audio.update(system, world, 0.25)
	assert(!audio.is_playing(system, entity, "stream"), "MP3 stops when fade completes")
	assert(audio.play(system, world, entity, "stream"))
	assert(audio.stop(system, entity, "stream"))
	audio.update(system, world, 0.25)
	assert(audio.play(system, world, entity, "stream"))
	audio.update(system, world, 0.5)
	assert(audio.is_playing(system, entity, "stream"), "MP3 play cancels a pending stop")
	assert_volume(system, entity, "stream", 0.7)
	assert(audio.stop(system, entity, "stream", 0))
}

mixer_test :: proc(system: ^audio.Audio_System, world: ^ecs.World, entity: ecs.Entity) {
	assert(audio.set_bus_volume(&system.mixer, .master, 0.5))
	assert(audio.set_bus_volume(&system.mixer, .music, 0.4))
	assert(audio.play(system, world, entity, "stream"))
	assert_volume(system, entity, "stream", 0.14)
	assert(audio.stop(system, entity, "stream", 1))
	assert(audio.fade_bus(&system.mixer, .music, 0, 1))
	audio.update(system, world, 0.5)
	assert_volume(system, entity, "stream", 0.035)
	assert(audio.mute_bus(&system.mixer, .music, true))
	audio.update(system, world, 0)
	assert_volume(system, entity, "stream", 0)
	assert(audio.mute_bus(&system.mixer, .music, false))
	audio.update(system, world, 0)
	assert_volume(system, entity, "stream", 0.035)
	audio.update(system, world, 0.5)
	assert(!audio.is_playing(system, entity, "stream"))
	assert(audio.set_bus_volume(&system.mixer, .master, 1))
	assert(audio.set_bus_volume(&system.mixer, .music, 1))
}

suspension_test :: proc(system: ^audio.Audio_System, world: ^ecs.World, entity: ecs.Entity) {
	for name in ([]string{"loop", "oneshot", "stream"}) {
		assert(audio.play(system, world, entity, name))
		assert(audio.stop(system, entity, name))
		audio.update(system, world, 0.25)
		key := ecs.Component_Instance{entity = entity, name = name}
		half_volume := system.instances[key].volume
		assert(ecs.set_enabled(world, entity, false))
		audio.update(system, world, 10)
		assert(!audio.is_playing(system, entity, name), "disabled audio suspends native playback")
		assert_volume(system, entity, name, half_volume)
		assert(ecs.set_enabled(world, entity, true))
		audio.update(system, world, 0)
		assert(audio.is_playing(system, entity, name), "enable resumes the remaining fade")
		assert_volume(system, entity, name, half_volume)
		audio.update(system, world, 0.25)
		assert(!audio.is_playing(system, entity, name))
	}
	assert(audio.play(system, world, entity, "loop"))
	assert(ecs.set_enabled(world, entity, false))
	audio.update(system, world, 0)
	assert(audio.stop(system, entity, "loop"), "stop also clears suspended audio")
	assert(!audio.is_stopping(system, entity, "loop"))
	assert(ecs.set_enabled(world, entity, true))
	audio.update(system, world, 1)
	assert(!audio.is_playing(system, entity, "loop"), "stopping disabled audio cancels its pending resume")
}

main :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	configuration_test(&registry)
	runtime := false
	for arg in os.args[1:] {if arg == "--runtime" {runtime = true}}
	if !runtime {
		fmt.println("Audio stop fade configuration validation passed (use --runtime for playback checks)")
		return
	}
	world := ecs.init()
	defer ecs.destroy(&world)
	entity := ecs.create_entity(&world)
	assert(ecs.add_component(&world, &registry, entity, "AudioPlayer", parse(`{
		"loop":{"sound":"examples/asteroids/assets/thruster.wav","volume":0.8,"looping":true,"play_on_start":true,"fade_out_on_stop":0.5},
		"oneshot":{"sound":"examples/audio_components/assets/bell.wav","volume":0.6,"max_voices":3,"fade_out_on_stop":0.5},
		"stream":{"sound":"examples/asteroids/assets/music.mp3","volume":0.7,"bus":"music","looping":true,"fade_out_on_stop":0.5}
	}`)))
	system := audio.init(".")
	defer audio.shutdown(&system)
	assert(system.available, "audio device required for stop fade validation")
	rl.SetMasterVolume(0) // Keep engine gains measurable while native playback is silent.
	preload_test(&system,&world,&registry)
	loop_test(&system, &world, entity)
	voice_test(&system, &world, entity)
	stream_test(&system, &world, entity)
	mixer_test(&system, &world, entity)
	suspension_test(&system, &world, entity)
	ecs.destroy_entity(&world, entity)
	audio.update(&system, &world, 1)
	assert(len(system.instances) == 0, "destroy releases stopped audio resources")
	fmt.println("Audio preload and stop fade: configuration, variants, voices, MP3, reload, loops, overrides, autoplay, replay, mixer, and suspension passed")
}
