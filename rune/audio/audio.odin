package audio

import "core:math"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "rune:ecs"
import rl "vendor:raylib"

Audio_Voice :: struct {
	suspended: bool,
	sound:         rl.Sound,
	volume_offset: f32,
	pitch_offset:  f32,
	sequence:      u64,
}

Audio_Instance :: struct {
	suspended: bool,
	resume_stream: bool,
	sound:                rl.Sound,
	voices:               [dynamic]Audio_Voice,
	music:                rl.Music,
	streaming:            bool,
	path:                 string,
	started:              bool,
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
}

init :: proc(project_root: string) -> Audio_System {
	arena, _ := mem.new(mem.Dynamic_Arena)
	assert(arena != nil)
	mem.dynamic_arena_init(arena)
	rl.InitAudioDevice()
	system := Audio_System {
		mixer            = default_mixer(),
		instances        = make(map[ecs.Component_Instance]Audio_Instance),
		retained_strings = make(map[string]string),
		arena            = arena,
		available        = rl.IsAudioDeviceReady(),
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
	if system.available && rl.IsAudioDeviceReady() {rl.CloseAudioDevice()}
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
		_, instance_exists := system.instances[key]
		// Deferred players load only when explicitly played.
		if !instance_exists && !player.play_on_start {continue}
		if !ensure_instance(system, key, player.sound) {continue}
		instance := system.instances[key]
		starting := player.play_on_start && !instance.started
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
	if !found || !ensure_instance(system, key, player.sound) {return false}
	listener_entity, _, listener_found := ecs.active_audio_listener(world)
	instance := system.instances[key]
	if !instance.streaming && !player.looping {
		play_one_shot(system, world, key, player, listener_entity, listener_found)
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

stop :: proc(system: ^Audio_System, entity: ecs.Entity, instance_name: string) -> bool {
	if !system.available {return false}
	key := ecs.Component_Instance {
		entity = entity,
		name   = instance_name,
	}
	instance, found := system.instances[key]
	if !found {return false}
	if instance.streaming {
		rl.StopMusicStream(instance.music)
	} else {
		for &voice in instance.voices {rl.StopSound(voice.sound); voice.suspended = false}
	}
	instance.resume_stream = false
	instance.started = false
	system.instances[key] = instance
	return true
}

is_playing :: proc(system: ^Audio_System, entity: ecs.Entity, instance_name: string) -> bool {
	instance, found :=
		system.instances[ecs.Component_Instance{entity = entity, name = instance_name}]
	if !system.available || !found {return false}
	if instance.streaming {return rl.IsMusicStreamPlaying(instance.music)}
	for voice in instance.voices {
		if rl.IsSoundPlaying(voice.sound) {return true}
	}
	return false
}

ensure_instance :: proc(system: ^Audio_System, key: ecs.Component_Instance, path: string) -> bool {
	if instance, found := system.instances[key]; found {
		if instance.path == path {return true}
		unload_instance(instance)
		delete_key(&system.instances, key)
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
	if is_streaming_path(path) {
		music := rl.LoadMusicStream(path_cstring)
		if !rl.IsMusicValid(music) {return false}
		owned_key := key
		owned_key.name = retain_string(system, key.name)
		system.instances[owned_key] = Audio_Instance {
			music     = music,
			streaming = true,
			path      = retain_string(system, path),
		}
	} else {
		sound := rl.LoadSound(path_cstring)
		if !rl.IsSoundValid(sound) {return false}
		voices := make([dynamic]Audio_Voice)
		append(&voices, Audio_Voice{sound = sound})
		owned_key := key
		owned_key.name = retain_string(system, key.name)
		system.instances[owned_key] = Audio_Instance {
			sound  = sound,
			voices = voices,
			path   = retain_string(system, path),
		}
	}
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
	gain := spatial_gain*bus_gain(&system.mixer,player.bus)
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
	for len(instance.voices) < int(target) {
		append(&instance.voices, Audio_Voice{sound = rl.LoadSoundAlias(instance.sound)})
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
	pan: f32 = 0.5
	if player.spatial && listener_found {
		listener_transform, listener_has_transform := ecs.get_transform(world, listener_entity)
		player_transform, player_has_transform := ecs.get_transform(world, entity)
		if listener_has_transform && player_has_transform {
			dx := player_transform.position[0] - listener_transform.position[0]
			dy := player_transform.position[1] - listener_transform.position[1]
			dz := player_transform.position[2] - listener_transform.position[2]
			distance := f32(math.sqrt(f64(dx * dx + dy * dy + dz * dz)))
			gain = attenuation(distance, player.min_distance, player.max_distance)
			if player.max_distance > 0 {pan = clamp(0.5 + 0.5 * dx / player.max_distance, 0, 1)}
		}
	}
	return gain, pan
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
	} else if rl.IsSoundValid(instance.sound) {
		for i := 1; i < len(instance.voices); i += 1 {
			if rl.IsSoundValid(
				instance.voices[i].sound,
			) {rl.UnloadSoundAlias(instance.voices[i].sound)}
		}
		delete(instance.voices)
		rl.UnloadSound(instance.sound)
	}
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
