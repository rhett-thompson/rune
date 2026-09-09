package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "rune:audio"
import "rune:ecs"
import "rune:scene"
import rl "vendor:raylib"

main :: proc() {
	mixer := audio.default_mixer()
	assert(audio.set_bus_volume(&mixer,.master,0.5))
	assert(audio.set_bus_volume(&mixer,.music,0.4))
	assert(audio.bus_gain(&mixer,.music)==0.2 && audio.bus_gain(&mixer,.master)==0.5)
	assert(!audio.set_bus_volume(&mixer,.ui,-1))
	assert(!audio.fade_bus(&mixer,.ui,1,-1))
	assert(audio.fade_bus(&mixer,.music,0,2))
	audio.update_mixer(&mixer,1)
	assert(math.abs(audio.bus_gain(&mixer,.music)-0.1)<0.0001)
	assert(audio.mute_bus(&mixer,.music,true))
	audio.update_mixer(&mixer,0.5)
	assert(audio.bus_gain(&mixer,.music)==0 && mixer.buses[.sfx].volume==1)
	assert(audio.mute_bus(&mixer,.music,false))
	assert(audio.fade_bus(&mixer,.music,1,1))
	audio.update_mixer(&mixer,2)
	assert(audio.bus_gain(&mixer,.music)==0.5)
	assert(audio.mute_bus(&mixer,.master,true) && audio.bus_gain(&mixer,.sfx)==0)
	data: json.Value
	source: string = `{"sound":"bell.wav","bus":"music"}`
	assert(json.unmarshal(transmute([]u8)source,&data)==nil)
	player, ok := ecs.audio_player_from_json(data)
	assert(ok && player.bus==.music)
	json.destroy_value(data)
	clip_configuration_test()
	for arg in os.args[1:] {if arg=="--runtime" {runtime_test()}}
	fmt.println("Audio mixer: routing, master gain, mute, interrupted fades and validation passed")
}

runtime_test :: proc() {
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, ok := scene.load("examples/audio_components/scenes/main.scene.json",&registry)
	assert(ok)
	defer ecs.destroy(&world)
	system := audio.init("examples/audio_components")
	defer audio.shutdown(&system)
	assert(system.available)
	audio.set_bus_volume(&system.mixer,.master,0) // Exercise native playback silently.
	entity, found := ecs.find_entity_by_id(&world,"bell_sphere")
	assert(found)
	for _ in 0..<3 {assert(audio.play(&system,&world,entity,"bell"))}
	key := ecs.Component_Instance{entity=entity,name="bell"}
	assert(len(system.instances[key].voices)==3)
	audio.update(&system,&world,0.01)
	assert(system.instances[key].volume==0)
	player, _ := ecs.get_audio_player(&world,entity,"bell")
	player.bus = .music
	assert(ecs.set_audio_player(&world,entity,"bell",player))
	audio.fade_bus(&system.mixer,.music,0,1)
	audio.update(&system,&world,0.5)
	assert(system.mixer.buses[.music].volume==0.5)
	assert(audio.stop(&system,entity,"bell"))
	random_clip_runtime_test(&system, &world, entity)
	assert(ecs.remove_component_instance(&world,entity,"AudioPlayer","bell"))
	audio.update(&system,&world,0.5)
	assert(len(system.instances)==0)
}

clip_configuration_test :: proc() {
	for source in ([]string{`{}`, `{"clips":[]}`, `{"clips":[""]}`, `{"clips":[1]}`, `{"clips":"bell.wav"}`}) {
		data: json.Value
		assert(json.unmarshal(transmute([]u8)source, &data) == nil)
		_, valid := ecs.audio_player_from_json(data)
		assert(!valid)
		json.destroy_value(data)
	}
	for source in ([]string{`{"sound":"bell.wav"}`, `{"clips":["a.wav","b.wav"]}`, `{"sound":"bell.wav","clips":[]}`}) {
		data: json.Value
		assert(json.unmarshal(transmute([]u8)source, &data) == nil)
		_, valid := ecs.audio_player_from_json(data)
		assert(valid)
		json.destroy_value(data)
	}
	// No fixed clip-count limit; random selection only returns configured entries.
	clips := make([]string, 257)
	defer delete(clips)
	for &clip in clips {clip = "many.wav"}
	player := ecs.default_audio_player()
	player.clips = clips
	assert(audio.select_clip(player) == "many.wav")
	fmt.println("Audio clips: single/list configuration and arbitrary clip counts passed")
}

random_clip_runtime_test :: proc(system: ^audio.Audio_System, world: ^ecs.World, entity: ecs.Entity) {
	player, _ := ecs.get_audio_player(world, entity, "bell")
	clips := [4]string{
		"../first_person_3d/assets/audio/concrete_1.wav",
		"../first_person_3d/assets/audio/concrete_2.wav",
		"../first_person_3d/assets/audio/concrete_3.wav",
		"../first_person_3d/assets/audio/concrete_4.wav",
	}
	player.clips = clips[:]
	player.max_voices = 3
	assert(ecs.set_audio_player(world, entity, "bell", player))
	clips[0] = "caller-mutated.wav"
	owned, _ := ecs.get_audio_player(world, entity, "bell")
	assert(owned.clips[0] != clips[0], "setter must own the array")
	rl.SetRandomSeed(91234)
	key := ecs.Component_Instance{entity=entity, name="bell"}
	seen := make(map[string]bool)
	defer delete(seen)
	for _ in 0..<64 {
		assert(audio.play(system, world, entity, "bell"))
		instance := system.instances[key]
		assert(len(instance.voices) == 3)
		seen[instance.path] = true
		assert(instance.sources[instance.path].frameCount > 0)
		selected := instance.path
		audio.update(system, world, 0)
		assert(system.instances[key].path == selected, "updates must not reselect")
	}
	assert(len(seen) == 4 && len(system.instances[key].sources) == 4)
	assert(system.instances[key].next_sequence == 64)
	// Different clips coexist in the bounded voice pool.
	voice_paths := make(map[string]bool)
	defer delete(voice_paths)
	for voice in system.instances[key].voices {voice_paths[voice.path] = true}
	assert(len(voice_paths) > 1)
	assert(audio.stop(system, entity, "bell"))
	assert(!audio.is_playing(system, entity, "bell"))
	owned.looping = true
	assert(ecs.set_audio_player(world, entity, "bell", owned))
	assert(audio.play(system, world, entity, "bell"))
	assert(audio.is_playing(system, entity, "bell"))
	selected := system.instances[key].path
	audio.update(system, world, 0)
	assert(system.instances[key].path == selected)
	assert(audio.stop(system, entity, "bell") && !audio.is_playing(system, entity, "bell"))
	owned.clips = {"assets/bell.wav"}
	owned.looping = false
	owned.play_on_start = true
	assert(ecs.set_audio_player(world, entity, "bell", owned))
	audio.update(system, world, 0)
	assert(system.instances[key].path == "assets/bell.wav" && len(system.instances[key].sources) == 1)
	assert(system.instances[key].next_sequence == 1, "autoplay should start once after clip edits")
	audio.update(system, world, 0)
	assert(system.instances[key].next_sequence == 1)
	owned.play_on_start = false
	owned.clips = {"../asteroids/assets/music.mp3", "assets/bell.wav"}
	assert(ecs.set_audio_player(world, entity, "bell", owned))
	saw_stream, saw_buffer: bool
	for _ in 0..<16 {
		assert(audio.play(system, world, entity, "bell"))
		instance := system.instances[key]
		if instance.streaming {saw_stream = true; assert(len(instance.voices) == 0)} else {saw_buffer = true}
		audio.update(system, world, 0)
		assert(audio.is_playing(system, entity, "bell"))
	}
	assert(saw_stream && saw_buffer)
	assert(audio.stop(system, entity, "bell"))
	fmt.println("Audio clips runtime: selection, cache, voices, stop/loop/autoplay, edits and mixed streaming passed")
}
