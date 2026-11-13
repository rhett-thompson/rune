package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:sync"
import "core:time"
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
	audio_device_lifecycle_test()
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, ok := scene.load("examples/audio_components/scenes/main.scene.json",&registry)
	assert(ok)
	defer ecs.destroy(&world)
	system := audio.init("examples/audio_components")
	defer audio.shutdown(&system)
	assert(system.available)
	master := rl.GetMasterVolume()
	// Mute the hardware output after raylib's mixed processors.
	rl.SetMasterVolume(0)
	defer rl.SetMasterVolume(master)
	entity, found := ecs.find_entity_by_id(&world,"bell_sphere")
	assert(found)
	reverb_runtime_test(&system, &world, entity)
	audio.set_bus_volume(&system.mixer,.master,0) // Exercise native playback silently.
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
	rebind_runtime_test(&system,&registry)
}

reverb_frames: u32
reverb_has_signal: u32

observe_reverb_output :: proc "c" (data: rawptr, frames: c.uint) {
	samples := ([^]f32)(data)[:int(frames) * 2]
	for sample in samples {
		if abs(sample) > 0.0001 {
			sync.atomic_store(&reverb_has_signal, 1)
			break
		}
	}
	sync.atomic_add(&reverb_frames, u32(frames))
}

reverb_output_has_signal :: proc(minimum_frames: u32) -> bool {
	// Attaching and detaching wait for the current device block, so consecutive
	// observations cannot mix old and new playback phases.
	sync.atomic_store(&reverb_frames, 0)
	sync.atomic_store(&reverb_has_signal, 0)
	rl.AttachAudioMixedProcessor(observe_reverb_output)
	started := time.tick_now()
	for sync.atomic_load(&reverb_frames) < minimum_frames && time.tick_since(started) < 2*time.Second {
		time.sleep(2*time.Millisecond)
	}
	rl.DetachAudioMixedProcessor(observe_reverb_output)
	assert(sync.atomic_load(&reverb_frames) >= minimum_frames, "audio device delivered mix samples")
	return sync.atomic_load(&reverb_has_signal) != 0
}

reverb_runtime_test :: proc(system: ^audio.Audio_System, world: ^ecs.World, entity: ecs.Entity) {
	player, found := ecs.get_audio_player(world, entity, "bell")
	assert(found)
	defer assert(ecs.set_audio_player(world, entity, "bell", player))
	assert(audio.set_bus_reverb(system, .sfx, 0.8))
	for bus in ([2]audio.Bus{.ui, .sfx}) {
		configured := player
		configured.bus, configured.spatial, configured.random_pitch = bus, false, 0
		assert(ecs.set_audio_player(world, entity, "bell", configured))
		assert(audio.play(system, world, entity, "bell"))
		assert(reverb_output_has_signal(8192), "the buffered alias plays normally on its bus")
		assert(audio.stop(system, entity, "bell", 0))
		assert(!audio.is_playing(system, entity, "bell"))
		assert(reverb_output_has_signal(2048) == (bus == .sfx), "only the selected bus has a tail after the alias stops")
	}
	fmt.println("Audio reverb runtime: native one-shot, isolated bus and tail after stop passed")
}

rebind_runtime_test :: proc(system: ^audio.Audio_System, registry: ^ecs.Component_Registry) {
	for streaming in ([2]bool{false,true}) {
		previous, previous_ok := scene.load("examples/audio_components/scenes/main.scene.json",registry)
		next, next_ok := scene.load("examples/audio_components/scenes/main.scene.json",registry)
		assert(previous_ok && next_ok)
		defer ecs.destroy(&next)
		source, _ := ecs.find_entity_by_id(&previous,"bell_sphere")
		destination, _ := ecs.find_entity_by_id(&next,"bell_sphere")
		configured, _ := ecs.get_audio_player(&previous,source,"bell")
		configured.spatial=false; configured.random_pitch=0; configured.pitch=1
		configured.looping=streaming; configured.play_on_start=streaming
		if streaming {configured.sound="../asteroids/assets/music.mp3"}
		assert(ecs.set_audio_player(&previous,source,"bell",configured))
		assert(ecs.set_audio_player(&next,destination,"bell",configured))
		for _ in 0..<(1 if streaming else 3) {assert(audio.play(system,&previous,source,"bell"))}
		for _ in 0..<8 {audio.update(system,&previous,0.02); time.sleep(20*time.Millisecond)}
		before := system.instances[ecs.Component_Instance{entity=source,name="bell"}]
		elapsed_before: f32
		if streaming {elapsed_before=rl.GetMusicTimePlayed(before.music); assert(elapsed_before>0)}
		assert(audio.rebind(system,&next,source,"bell",destination,"bell"))
		ecs.destroy(&previous)
		audio.update(system,&next,0.02)
		after := system.instances[ecs.Component_Instance{entity=destination,name="bell"}]
		assert(len(system.instances)==1 && audio.is_playing(system,destination,"bell"))
		if streaming {
			assert(after.music.stream.buffer==before.music.stream.buffer && rl.GetMusicTimePlayed(after.music)>=elapsed_before,
				"scene replacement retains the same advancing decoder instead of restarting music")
		} else {
			assert(raw_data(after.voices)==raw_data(before.voices) && len(after.voices)==3 && after.next_sequence==3,
				"buffered aliases move together without selecting or replaying another voice")
		}
		assert(ecs.remove_component_instance(&next,destination,"AudioPlayer","bell"))
		audio.update(system,&next,0.02)
		assert(len(system.instances)==0,"the destination owns final resource release")
	}
	fmt.println("Audio rebind runtime: advancing stream, buffered aliases and destination cleanup passed")
}

audio_device_lifecycle_test :: proc() {
	assert(!rl.IsAudioDeviceReady(), "lifecycle validation starts without an audio device")
	owner := audio.init(".")
	defer audio.shutdown(&owner)
	assert(owner.available && owner.owns_device && rl.IsAudioDeviceReady(), "Rune opens and owns a fresh audio device")
	borrower := audio.init(".")
	defer audio.shutdown(&borrower)
	assert(borrower.available && !borrower.owns_device, "a second audio system borrows the open device")
	audio.shutdown(&borrower)
	assert(rl.IsAudioDeviceReady(), "borrower shutdown leaves the owner's device open")
	audio.shutdown(&borrower)
	assert(rl.IsAudioDeviceReady(), "repeated borrower shutdown leaves the owner's device open")
	audio.shutdown(&owner)
	assert(!rl.IsAudioDeviceReady(), "owner shutdown closes its audio device")

	owner = audio.init(".")
	assert(owner.available && owner.owns_device && rl.IsAudioDeviceReady(), "Rune can reopen audio after owner shutdown")
	audio.shutdown(&owner)
	assert(!rl.IsAudioDeviceReady())

	rl.InitAudioDevice()
	defer if rl.IsAudioDeviceReady() {rl.CloseAudioDevice()}
	assert(rl.IsAudioDeviceReady(), "audio device required for runtime validation")
	external_borrower := audio.init(".")
	defer audio.shutdown(&external_borrower)
	assert(external_borrower.available && !external_borrower.owns_device, "Rune borrows an externally initialized device")
	audio.shutdown(&external_borrower)
	assert(rl.IsAudioDeviceReady(), "Rune shutdown preserves an externally owned device")
	audio.shutdown(&external_borrower)
	assert(rl.IsAudioDeviceReady(), "repeated Rune shutdown preserves an externally owned device")
	rl.CloseAudioDevice()
	assert(!rl.IsAudioDeviceReady())
	fmt.println("Audio device lifecycle: owned init, borrowing, shutdown and reinitialization passed")
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
