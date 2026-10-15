package audio

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "rune:ecs"
import rl "vendor:raylib"

Audio_Voice :: struct {
	path: string,
	suspended: bool,
	sound:         rl.Sound,
	volume_offset: f32,
	pitch_offset:  f32,
	sequence:      u64,
}

Audio_Instance :: struct {
	suspended: bool,
	resume_stream: bool,
	resume_sound: bool,
	configured_sound: string,
	configured_clips: []string,
	sources: map[string]rl.Sound,
	sound:                rl.Sound,
	voices:               [dynamic]Audio_Voice,
	music:                rl.Music,
	streaming:            bool,
	path:                 string,
	started:              bool,
	stop_requested:       bool,
	stop_fading:          bool,
	fade_out_on_stop:     f32,
	stop_fade_duration, stop_fade_elapsed: f32,
	settings_initialized: bool,
	volume, pitch, pan:   f32,
	volume_offset:        f32,
	pitch_offset:         f32,
	next_sequence:        u64,
}

// Audio_System owns one raylib playback instance per named AudioPlayer
// component instance. Short clips are buffered Sounds; music formats stream.
Audio_System :: struct {
	mixer:            Mixer,
	root:             string,
	instances:        map[ecs.Component_Instance]Audio_Instance,
	retained_strings: map[string]string,
	arena:            ^mem.Dynamic_Arena,
	available:        bool,
	owns_device:      bool,
}

init :: proc(project_root: string) -> Audio_System {
	arena, _ := mem.new(mem.Dynamic_Arena)
	assert(arena != nil)
	mem.dynamic_arena_init(arena)
	// raylib's device is process-wide; reuse a device opened by another owner.
	opened_device := !rl.IsAudioDeviceReady()
	if opened_device {rl.InitAudioDevice()}
	available := rl.IsAudioDeviceReady()
	system := Audio_System {
		mixer            = default_mixer(),
		instances        = make(map[ecs.Component_Instance]Audio_Instance),
		retained_strings = make(map[string]string),
		arena            = arena,
		available        = available,
		owns_device      = opened_device && available,
	}
	system.root = retain_string(&system, project_root)
	return system
}

shutdown :: proc(system: ^Audio_System) {
	if system == nil {return}
	for _, instance in system.instances {
		unload_instance(instance)
	}
	delete(system.instances)
	delete(system.retained_strings)
	if system.owns_device && rl.IsAudioDeviceReady() {rl.CloseAudioDevice()}
	if system.arena != nil {
		mem.dynamic_arena_destroy(system.arena)
		mem.free(system.arena)
	}
	system^ = {}
}

retain_string :: proc(system: ^Audio_System, value: string) -> string {
	if len(value) == 0 {return ""}
	if owned, found := system.retained_strings[value]; found {return owned}
	owned, _ := strings.clone(value, mem.dynamic_arena_allocator(system.arena))
	system.retained_strings[owned] = owned
	return owned
}

// update synchronizes configured players, starts play_on_start sounds, and
// restarts looping sounds when raylib reports that their current play ended.
update :: proc(system: ^Audio_System, world: ^ecs.World, dt: f32 = 0) {
	update_mixer(&system.mixer,dt)
	if !system.available {return}
	remove_missing_instances(system, world)
	if len(world.audio_players) == 0 {return}
	listener_entity, _, listener_found := ecs.active_audio_listener(world)
	// The typed instance table already contains every entity/name pair. Walking
	// it once avoids scanning all instances again for each audio entity.
	for key, player in world.audio_players {
		enabled := ecs.is_enabled(world, key.entity)
		suspend_instance(system, key, !enabled)
		if !enabled {continue}
		current, instance_exists := system.instances[key]
		// Deferred players load only when explicitly played.
		if !instance_exists && !player.play_on_start {continue}
		if !ensure_instance(system, key, player, !instance_exists || (player.play_on_start && !current.started && !current.stop_requested)) {continue}
		instance := system.instances[key]
		instance.fade_out_on_stop = player.fade_out_on_stop
		if instance.stop_fading && dt > 0 && !math.is_nan(dt) && !math.is_inf(dt) {
			instance.stop_fade_elapsed = min(instance.stop_fade_duration, instance.stop_fade_elapsed+dt)
			if instance.stop_fade_elapsed >= instance.stop_fade_duration {stop_instance(&instance)}
		}
		system.instances[key] = instance
		starting := player.play_on_start && !instance.started && !instance.stop_requested
		restarting :=
			!instance.streaming &&
			player.looping &&
			instance.started &&
			!rl.IsSoundPlaying(instance.sound)
		if starting && !instance.streaming && !player.looping {
			play_one_shot(system, world, key, player, listener_entity, listener_found)
			instance = system.instances[key]
			instance.started = true
			system.instances[key] = instance
			continue
		}
		if starting || restarting {randomize_settings(system, key, player)}
		apply_settings(system, world, key, player, listener_entity, listener_found)
		instance = system.instances[key]
		if starting {
			play_instance(instance)
			instance.started = true
			system.instances[key] = instance
		} else if restarting {
			rl.PlaySound(instance.sound)
		}
		if instance.streaming && instance.started {
			instance.music.looping = player.looping
			rl.UpdateMusicStream(instance.music)
			system.instances[key] = instance
		}
	}
}

play :: proc(
	system: ^Audio_System,
	world: ^ecs.World,
	entity: ecs.Entity,
	instance_name: string,
) -> bool {
	if !system.available || !ecs.is_enabled(world, entity) {return false}
	key := ecs.Component_Instance {
		entity = entity,
		name   = instance_name,
	}
	suspend_instance(system, key, false)
	player, found := ecs.get_audio_player(world, entity, instance_name)
	if !found || !ensure_instance(system, key, player, true) {return false}
	listener_entity, _, listener_found := ecs.active_audio_listener(world)
	instance := system.instances[key]
	instance.fade_out_on_stop = player.fade_out_on_stop
	instance.stop_requested, instance.stop_fading = false, false
	instance.stop_fade_duration, instance.stop_fade_elapsed = 0, 0
	instance.settings_initialized = false
	system.instances[key] = instance
	if !instance.streaming && !player.looping {
		play_one_shot(system, world, key, player, listener_entity, listener_found)
		apply_settings(system, world, key, player, listener_entity, listener_found)
		return true
	}
	randomize_settings(system, key, player)
	apply_settings(system, world, key, player, listener_entity, listener_found)
	instance = system.instances[key]
	play_instance(instance)
	instance.started = true
	system.instances[key] = instance
	return true
}

// Negative one uses the configured duration; zero forces an immediate stop.
// Repeated requests leave an in-progress fade's remaining time unchanged.
stop :: proc(system: ^Audio_System, entity: ecs.Entity, instance_name: string, fade_seconds: f32 = -1) -> bool {
	if !system.available || math.is_nan(fade_seconds) || math.is_inf(fade_seconds) || (fade_seconds < 0 && fade_seconds != -1) {return false}
	key := ecs.Component_Instance {
		entity = entity,
		name   = instance_name,
	}
	instance, found := system.instances[key]
	if !found {return false}
	duration := instance.fade_out_on_stop if fade_seconds == -1 else fade_seconds
	if duration > 0 && !instance.suspended && is_playing(system,entity,instance_name) {
		if instance.stop_fading {return true}
		instance.stop_requested, instance.stop_fading = true, true
		instance.stop_fade_duration, instance.stop_fade_elapsed = duration, 0
	} else {
		stop_instance(&instance)
	}
	system.instances[key] = instance
	return true
}

stop_instance :: proc(instance: ^Audio_Instance) {
	if instance.streaming {rl.StopMusicStream(instance.music)}
	else {
		rl.StopSound(instance.sound)
		for &voice in instance.voices {rl.StopSound(voice.sound); voice.suspended = false}
	}
	instance.resume_stream, instance.resume_sound = false, false
	instance.started, instance.stop_fading = false, false
	instance.stop_requested = true
	instance.stop_fade_duration, instance.stop_fade_elapsed = 0, 0
	instance.settings_initialized = false
}

stop_fade_gain :: proc(instance: Audio_Instance) -> f32 {
	if !instance.stop_requested {return 1}
	if !instance.stop_fading {return 0}
	return clamp(1-instance.stop_fade_elapsed/instance.stop_fade_duration,0,1)
}

is_stopping :: proc(system: ^Audio_System, entity: ecs.Entity, instance_name: string) -> bool {
	instance, found := system.instances[ecs.Component_Instance{entity=entity,name=instance_name}]
	return system.available && found && instance.stop_fading
}

is_playing :: proc(system: ^Audio_System, entity: ecs.Entity, instance_name: string) -> bool {
	instance, found :=
		system.instances[ecs.Component_Instance{entity = entity, name = instance_name}]
	if !system.available || !found {return false}
	if instance.streaming {return rl.IsMusicStreamPlaying(instance.music)}
	if rl.IsSoundPlaying(instance.sound) {return true}
	for voice in instance.voices {
		if rl.IsSoundPlaying(voice.sound) {return true}
	}
	return false
}

select_clip :: proc(player: ecs.AudioPlayer) -> string {
	if len(player.clips) == 0 {return player.sound}
	return player.clips[rl.GetRandomValue(0, i32(len(player.clips)-1))]
}

same_clip_configuration :: proc(instance: Audio_Instance, player: ecs.AudioPlayer) -> bool {
	if instance.configured_sound != player.sound || len(instance.configured_clips) != len(player.clips) {return false}
	for clip, i in player.clips {if instance.configured_clips[i] != clip {return false}}
	return true
}

ensure_instance :: proc(system: ^Audio_System, key: ecs.Component_Instance, player: ecs.AudioPlayer, choose: bool) -> bool {
	instance, found := system.instances[key]
	if found && !same_clip_configuration(instance, player) {
		unload_instance(instance)
		delete_key(&system.instances, key)
		instance, found = {}, false
	}
	if found && !choose {return true}
	path := select_clip(player)
	if found && instance.path == path {return true}
	streaming := is_streaming_path(path)
	if found && !instance.streaming && !streaming {
		if sound, cached := instance.sources[path]; cached {
			rl.StopSound(instance.sound) // A looping source restarts; aliases remain independent.
			instance.sound, instance.path = sound, retain_string(system, path)
			instance.settings_initialized = false
			system.instances[key] = instance
			return true
		}
	}
	full_path := path
	joined_path: string
	defer if len(joined_path) > 0 {delete(joined_path)}
	if !filepath.is_abs(full_path) {
		joined_path, _ = filepath.join({system.root, path})
		full_path = joined_path
	}
	path_cstring, _ := strings.clone_to_cstring(full_path)
	defer delete(path_cstring)
	music: rl.Music
	sound: rl.Sound
	if streaming {
		music = rl.LoadMusicStream(path_cstring)
		if !rl.IsMusicValid(music) {return false}
	} else {
		sound = rl.LoadSound(path_cstring)
		if !rl.IsSoundValid(sound) {return false}
	}
	// Streams remain a single playback channel. Buffered clips share a source
	// cache and a bounded alias pool, so selecting a new clip never cuts a tail.
	if found && (instance.streaming || streaming) {
		unload_instance(instance)
		instance, found = {}, false
	}
	if !found {
		instance.configured_sound = retain_string(system, player.sound)
		instance.configured_clips = make([]string, len(player.clips))
		for clip, i in player.clips {instance.configured_clips[i] = retain_string(system, clip)}
		if !streaming {
			instance.sources = make(map[string]rl.Sound)
			instance.voices = make([dynamic]Audio_Voice)
		}
	} else {rl.StopSound(instance.sound)}
	instance.path = retain_string(system, path)
	instance.streaming = streaming
	instance.settings_initialized = false
	if streaming {instance.music = music} else {
		instance.sound = sound
		instance.sources[instance.path] = sound
	}
	owned_key := key
	owned_key.name = retain_string(system, key.name)
	system.instances[owned_key] = instance
	return true
}

remove_missing_instances :: proc(system: ^Audio_System, world: ^ecs.World) {
	for key, instance in system.instances {
		if _, found := ecs.get_audio_player(world, key.entity, key.name); found {continue}
		unload_instance(instance)
		delete_key(&system.instances, key)
	}
}

apply_settings :: proc(
	system: ^Audio_System,
	world: ^ecs.World,
	key: ecs.Component_Instance,
	player: ecs.AudioPlayer,
	listener_entity: ecs.Entity,
	listener_found: bool,
) {
	instance := system.instances[key]
	spatial_gain, pan := spatial_factors(world,key.entity,player,listener_entity,listener_found)
	gain := spatial_gain*bus_gain(&system.mixer,player.bus)*stop_fade_gain(instance)
	volume := max(0, player.volume + instance.volume_offset)*gain
	pitch := max(0.01, player.pitch + instance.pitch_offset)
	if !instance.streaming && !player.looping {
		// Every alias has independent variation. Update active voices as well as
		// the source sound so bus fades cannot leave older one-shots audible.
		for voice in instance.voices {
			rl.SetSoundVolume(voice.sound,max(0,player.volume+voice.volume_offset)*gain)
			rl.SetSoundPitch(voice.sound,max(0.01,player.pitch+voice.pitch_offset))
			rl.SetSoundPan(voice.sound,pan)
		}
	}
	if instance.settings_initialized &&
	   instance.volume == volume &&
	   instance.pitch == pitch &&
	   instance.pan == pan {return}
	if instance.streaming {
		rl.SetMusicVolume(instance.music, volume)
		rl.SetMusicPitch(instance.music, pitch)
		rl.SetMusicPan(instance.music, pan)
	} else if player.looping {
		rl.SetSoundVolume(instance.sound, volume)
		rl.SetSoundPitch(instance.sound, pitch)
		rl.SetSoundPan(instance.sound, pan)
	}
	instance.settings_initialized = true
	instance.volume = volume
	instance.pitch = pitch
	instance.pan = pan
	system.instances[key] = instance
}

randomize_settings :: proc(
	system: ^Audio_System,
	key: ecs.Component_Instance,
	player: ecs.AudioPlayer,
) {
	instance := system.instances[key]
	instance.volume_offset = random_variation(player.random_volume)
	instance.pitch_offset = random_variation(player.random_pitch)
	instance.settings_initialized = false
	system.instances[key] = instance
}

random_variation :: proc(amount: f32) -> f32 {
	if amount <= 0 {return 0}
	unit := f32(rl.GetRandomValue(-100000, 100000)) / 100000
	return unit * amount
}

play_one_shot :: proc(
	system: ^Audio_System,
	world: ^ecs.World,
	key: ecs.Component_Instance,
	player: ecs.AudioPlayer,
	listener_entity: ecs.Entity,
	listener_found: bool,
) {
	instance := system.instances[key]
	ensure_voice_count(&instance, player.max_voices)
	voice_index := 0
	oldest_sequence := ~u64(0)
	for &voice, index in instance.voices {
		if !rl.IsSoundPlaying(voice.sound) {
			voice_index = index
			oldest_sequence = 0
			break
		}
		if voice.sequence < oldest_sequence {
			oldest_sequence = voice.sequence
			voice_index = index
		}
	}
	voice := &instance.voices[voice_index]
	if rl.IsSoundPlaying(voice.sound) {rl.StopSound(voice.sound)}
	if voice.path != instance.path {
		rl.UnloadSoundAlias(voice.sound)
		voice.sound = rl.LoadSoundAlias(instance.sound)
		voice.path = instance.path
	}
	voice.suspended = false
	voice.volume_offset = random_variation(player.random_volume)
	voice.pitch_offset = random_variation(player.random_pitch)
	instance.next_sequence += 1
	voice.sequence = instance.next_sequence
	spatial_gain, pan := spatial_factors(
		world,
		key.entity,
		player,
		listener_entity,
		listener_found,
	)
	volume := max(0, player.volume + voice.volume_offset) * spatial_gain * bus_gain(&system.mixer,player.bus)
	rl.SetSoundVolume(voice.sound, volume)
	rl.SetSoundPitch(voice.sound, max(0.01, player.pitch + voice.pitch_offset))
	rl.SetSoundPan(voice.sound, pan)
	rl.PlaySound(voice.sound)
	instance.started = true
	system.instances[key] = instance
}

ensure_voice_count :: proc(instance: ^Audio_Instance, requested: i32) {
	target := max(requested, 1)
	for len(instance.voices) > int(target) {
		rl.UnloadSoundAlias(instance.voices[len(instance.voices)-1].sound)
		pop(&instance.voices)
	}
	for len(instance.voices) < int(target) {
		append(&instance.voices, Audio_Voice{sound = rl.LoadSoundAlias(instance.sound), path = instance.path})
	}
}

spatial_factors :: proc(
	world: ^ecs.World,
	entity: ecs.Entity,
	player: ecs.AudioPlayer,
	listener_entity: ecs.Entity,
	listener_found: bool,
) -> (
	f32,
	f32,
) {
	gain: f32 = 1
	// raylib 6 uses signed stereo pan: -1 left, 0 center, +1 right.
	pan: f32 = 0
	if player.spatial && listener_found {
		if ecs.has_component_data(world, listener_entity, "Transform") &&
		   ecs.has_component_data(world, entity, "Transform") {
			listener_transform := ecs.world_transform_3d(world, listener_entity)
			player_transform := ecs.world_transform_3d(world, entity)
			offset := player_transform.position - listener_transform.position
			distance := linalg.length(offset)
			gain = attenuation(distance, player.min_distance, player.max_distance)
			if distance > 0 {
				right := listener_right(world, listener_entity, listener_transform)
				pan = clamp(linalg.dot(offset / distance, right), -1, 1)
			}
		}
	}
	return gain, pan
}

// Camera3D target/up are explicit world-space vectors, independent of its
// Transform rotation. Standalone listeners use their composed local +X axis.
listener_right :: proc(world: ^ecs.World, entity: ecs.Entity, transform: ecs.Transform) -> [3]f32 {
	if camera, found := ecs.get_camera_3d(world, entity); found {
		right := linalg.cross(camera.target - transform.position, camera.up)
		length := linalg.length(right)
		if length > 0.000001 && !math.is_nan(length) && !math.is_inf(length) {return right / length}
	}
	rotation := transform.rotation * f32(math.PI / 180)
	orientation := linalg.quaternion_from_pitch_yaw_roll(rotation[0], rotation[1], rotation[2])
	return linalg.quaternion_mul_vector3(orientation, [3]f32{1, 0, 0})
}

attenuation :: proc(distance, min_distance, max_distance: f32) -> f32 {
	if distance <= min_distance {return 1}
	if max_distance <= min_distance || distance >= max_distance {return 0}
	return 1 - (distance - min_distance) / (max_distance - min_distance)
}

is_streaming_path :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return(
		strings.has_suffix(lower, ".mp3") ||
		strings.has_suffix(lower, ".ogg") ||
		strings.has_suffix(lower, ".flac") ||
		strings.has_suffix(lower, ".xm") ||
		strings.has_suffix(lower, ".mod") ||
		strings.has_suffix(lower, ".qoa") \
	)
}

play_instance :: proc(instance: Audio_Instance) {
	if instance.streaming {rl.PlayMusicStream(instance.music)} else {rl.PlaySound(instance.sound)}
}

unload_instance :: proc(instance: Audio_Instance) {
	if instance.streaming {
		if rl.IsMusicValid(instance.music) {rl.UnloadMusicStream(instance.music)}
	} else {
		for voice in instance.voices {
			if rl.IsSoundValid(voice.sound) {rl.UnloadSoundAlias(voice.sound)}
		}
		delete(instance.voices)
		for _, sound in instance.sources {rl.UnloadSound(sound)}
		delete(instance.sources)
	}
	delete(instance.configured_clips)
}

// Activation is serviced by audio.update even while simulation is paused.
suspend_instance :: proc(system: ^Audio_System, key: ecs.Component_Instance, suspended: bool) {
	instance, found := system.instances[key]
	if !found || instance.suspended == suspended {return}
	if instance.streaming {
		if suspended {
			instance.resume_stream = rl.IsMusicStreamPlaying(instance.music)
			if instance.resume_stream {rl.PauseMusicStream(instance.music)}
		} else if instance.resume_stream {
			rl.ResumeMusicStream(instance.music)
			instance.resume_stream = false
		}
	} else {
		if suspended {
			instance.resume_sound = rl.IsSoundPlaying(instance.sound)
			if instance.resume_sound {rl.PauseSound(instance.sound)}
		} else if instance.resume_sound {
			rl.ResumeSound(instance.sound)
			instance.resume_sound = false
		}
		for &voice in instance.voices {
			if suspended {
				voice.suspended = rl.IsSoundPlaying(voice.sound)
				if voice.suspended {rl.PauseSound(voice.sound)}
			} else if voice.suspended {
				rl.ResumeSound(voice.sound)
				voice.suspended = false
			}
		}
	}
	instance.suspended = suspended
	system.instances[key] = instance
}
