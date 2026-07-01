package audio

import "core:math"
import "core:path/filepath"
import "core:strings"
import "rune:ecs"
import rl "vendor:raylib"

Audio_Instance :: struct {
	sound:                rl.Sound,
	music:                rl.Music,
	streaming:            bool,
	path:                 string,
	started:              bool,
	settings_initialized: bool,
	volume, pitch, pan:   f32,
}

// Audio_System owns one raylib playback instance per AudioPlayer entity. Short
// clips are buffered Sounds; music formats are streamed automatically.
Audio_System :: struct {
	root:      string,
	instances: map[ecs.Entity]Audio_Instance,
	available: bool,
}

init :: proc(project_root: string) -> Audio_System {
	rl.InitAudioDevice()
	return Audio_System{
		root = project_root,
		instances = make(map[ecs.Entity]Audio_Instance),
		available = rl.IsAudioDeviceReady(),
	}
}

shutdown :: proc(system: ^Audio_System) {
	for _, instance in system.instances {
		unload_instance(instance)
	}
	delete(system.instances)
	if system.available && rl.IsAudioDeviceReady() { rl.CloseAudioDevice() }
	system.available = false
}

// update synchronizes configured players, starts play_on_start sounds, and
// restarts looping sounds when raylib reports that their current play ended.
update :: proc(system: ^Audio_System, world: ^ecs.World) {
	if !system.available { return }
	remove_missing_instances(system, world)
	listener_entity, _, listener_found := ecs.active_audio_listener(world)
	for entity in ecs.entities_with_component(world, "AudioPlayer") {
		player, found := ecs.get_audio_player(world, entity)
		if !found { continue }
		_, instance_exists := system.instances[entity]
		// Deferred players load only when explicitly played. This avoids disk
		// work and repeated missing-file attempts for dormant scene emitters.
		if !instance_exists && !player.play_on_start { continue }
		if !ensure_instance(system, entity, player.sound) { continue }
		apply_settings(system, world, entity, player, listener_entity, listener_found)
		instance := system.instances[entity]
		if player.play_on_start && !instance.started {
			play_instance(instance)
			instance.started = true
			system.instances[entity] = instance
		} else if !instance.streaming && player.looping && instance.started && !rl.IsSoundPlaying(instance.sound) {
			rl.PlaySound(instance.sound)
		}
		if instance.streaming && instance.started {
			instance.music.looping = player.looping
			rl.UpdateMusicStream(instance.music)
			system.instances[entity] = instance
		}
	}
}

play :: proc(system: ^Audio_System, world: ^ecs.World, entity: ecs.Entity) -> bool {
	if !system.available { return false }
	player, found := ecs.get_audio_player(world, entity)
	if !found || !ensure_instance(system, entity, player.sound) { return false }
	listener_entity, _, listener_found := ecs.active_audio_listener(world)
	apply_settings(system, world, entity, player, listener_entity, listener_found)
	instance := system.instances[entity]
	play_instance(instance)
	instance.started = true
	system.instances[entity] = instance
	return true
}

stop :: proc(system: ^Audio_System, entity: ecs.Entity) -> bool {
	if !system.available { return false }
	instance, found := system.instances[entity]
	if !found { return false }
	if instance.streaming { rl.StopMusicStream(instance.music) } else { rl.StopSound(instance.sound) }
	instance.started = false
	system.instances[entity] = instance
	return true
}

is_playing :: proc(system: ^Audio_System, entity: ecs.Entity) -> bool {
	instance, found := system.instances[entity]
	if !system.available || !found { return false }
	return rl.IsMusicStreamPlaying(instance.music) if instance.streaming else rl.IsSoundPlaying(instance.sound)
}

ensure_instance :: proc(system: ^Audio_System, entity: ecs.Entity, path: string) -> bool {
	if instance, found := system.instances[entity]; found {
		if instance.path == path { return true }
		unload_instance(instance)
		delete_key(&system.instances, entity)
	}
	full_path := path
	if !filepath.is_abs(full_path) { full_path, _ = filepath.join({system.root, path}) }
	path_cstring, _ := strings.clone_to_cstring(full_path)
	if is_streaming_path(path) {
		music := rl.LoadMusicStream(path_cstring)
		if !rl.IsMusicValid(music) { return false }
		system.instances[entity] = Audio_Instance{music = music, streaming = true, path = path}
	} else {
		sound := rl.LoadSound(path_cstring)
		if !rl.IsSoundValid(sound) { return false }
		system.instances[entity] = Audio_Instance{sound = sound, path = path}
	}
	return true
}

remove_missing_instances :: proc(system: ^Audio_System, world: ^ecs.World) {
	for entity, instance in system.instances {
		if ecs.has_component_data(world, entity, "AudioPlayer") { continue }
		unload_instance(instance)
		delete_key(&system.instances, entity)
	}
}

apply_settings :: proc(system: ^Audio_System, world: ^ecs.World, entity: ecs.Entity, player: ecs.AudioPlayer, listener_entity: ecs.Entity, listener_found: bool) {
	instance := system.instances[entity]
	volume := player.volume
	pan: f32 = 0.5
	if player.spatial {
		if listener_found {
			listener_transform, listener_has_transform := ecs.get_transform(world, listener_entity)
			player_transform, player_has_transform := ecs.get_transform(world, entity)
			if listener_has_transform && player_has_transform {
				dx := player_transform.position[0] - listener_transform.position[0]
				dy := player_transform.position[1] - listener_transform.position[1]
				dz := player_transform.position[2] - listener_transform.position[2]
				distance := f32(math.sqrt(f64(dx * dx + dy * dy + dz * dz)))
				volume *= attenuation(distance, player.min_distance, player.max_distance)
				if player.max_distance > 0 {
					pan = clamp(0.5 + 0.5 * dx / player.max_distance, 0, 1)
				}
			}
		}
	}
	if instance.settings_initialized && instance.volume == volume && instance.pitch == player.pitch && instance.pan == pan { return }
	if instance.streaming {
		rl.SetMusicVolume(instance.music, volume)
		rl.SetMusicPitch(instance.music, player.pitch)
		rl.SetMusicPan(instance.music, pan)
	} else {
		rl.SetSoundVolume(instance.sound, volume)
		rl.SetSoundPitch(instance.sound, player.pitch)
		rl.SetSoundPan(instance.sound, pan)
	}
	instance.settings_initialized = true
	instance.volume = volume
	instance.pitch = player.pitch
	instance.pan = pan
	system.instances[entity] = instance
}

attenuation :: proc(distance, min_distance, max_distance: f32) -> f32 {
	if distance <= min_distance { return 1 }
	if max_distance <= min_distance || distance >= max_distance { return 0 }
	return 1 - (distance - min_distance) / (max_distance - min_distance)
}

is_streaming_path :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(lower, ".mp3") || strings.has_suffix(lower, ".ogg") ||
	       strings.has_suffix(lower, ".flac") || strings.has_suffix(lower, ".xm") ||
	       strings.has_suffix(lower, ".mod") || strings.has_suffix(lower, ".qoa")
}

play_instance :: proc(instance: Audio_Instance) {
	if instance.streaming { rl.PlayMusicStream(instance.music) } else { rl.PlaySound(instance.sound) }
}

unload_instance :: proc(instance: Audio_Instance) {
	if instance.streaming {
		if rl.IsMusicValid(instance.music) { rl.UnloadMusicStream(instance.music) }
	} else if rl.IsSoundValid(instance.sound) {
		rl.UnloadSound(instance.sound)
	}
}
