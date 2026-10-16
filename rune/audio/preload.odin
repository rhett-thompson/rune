package audio

import "core:path/filepath"
import "core:strings"
import "rune:ecs"
import rl "vendor:raylib"

// Load configured buffered variants and reserve the one-shot voice pool without
// playing, selecting a random clip, or changing active playback. Streams retain
// one channel: the first configured clip until an explicit play selects another.
// Disabled entities may preload before activation. The system owns all resources.
preload :: proc(system: ^Audio_System, world: ^ecs.World, entity: ecs.Entity, instance_name: string) -> bool {
	if system == nil || world == nil || !system.available || !ecs.is_alive(world,entity) {return false}
	player, valid := ecs.get_audio_player(world,entity,instance_name)
	if !valid {return false}
	key := ecs.Component_Instance{entity=entity,name=instance_name}
	previous, found := system.instances[key]
	reuse := found && same_clip_configuration(previous,player)
	instance: Audio_Instance
	if reuse {instance=previous}
	path := player.sound
	if len(player.clips)>0 {path=player.clips[0]}
	if path=="" {return false}
	if !reuse {instance.path=path; instance.streaming=is_streaming_path(path)}
	pending := make(map[string]rl.Sound)
	voices := make([dynamic]Audio_Voice)
	music: rl.Music
	success := false
	defer {
		if !success {
			for voice in voices {rl.UnloadSoundAlias(voice.sound)}
			for _, sound in pending {rl.UnloadSound(sound)}
			if rl.IsMusicValid(music) {rl.UnloadMusicStream(music)}
		}
		delete(voices); delete(pending)
	}
	if !reuse && instance.streaming {
		_, music, valid = load_source(system,path)
		if !valid {return false}
	}
	clips := player.clips
	if len(clips)==0 {clips=[]string{player.sound}}
	alias_path := ""
	if reuse && !instance.streaming {alias_path=instance.path}
	for clip in clips {
		if is_streaming_path(clip) {continue}
		if alias_path=="" {alias_path=clip}
		if _, cached := instance.sources[clip]; cached {continue}
		if _, cached := pending[clip]; cached {continue}
		sound, _, loaded := load_source(system,clip)
		if !loaded {return false}
		pending[clip]=sound
	}
	if alias_path!="" && !player.looping {
		sound, cached := instance.sources[alias_path]
		if !cached {sound=pending[alias_path]}
		// Never shrink an existing pool here: its last voices may still be heard.
		for len(instance.voices)+len(voices)<int(max(player.max_voices,1)) {
			alias := rl.LoadSoundAlias(sound)
			if !rl.IsSoundValid(alias) {return false}
			append(&voices,Audio_Voice{sound=alias,path=retain_string(system,alias_path)})
		}
	}
	if !reuse {
		instance.path=retain_string(system,instance.path)
		instance.configured_sound=retain_string(system,player.sound)
		instance.configured_clips=make([]string,len(player.clips))
		for clip,i in player.clips {instance.configured_clips[i]=retain_string(system,clip)}
		instance.fade_out_on_stop=player.fade_out_on_stop
		instance.music=music
	}
	if len(pending)>0 && instance.sources==nil {instance.sources=make(map[string]rl.Sound)}
	for clip,sound in pending {instance.sources[retain_string(system,clip)]=sound}
	if !reuse && !instance.streaming {instance.sound=instance.sources[instance.path]}
	append(&instance.voices,..voices[:])
	if found && !reuse {unload_instance(previous)}
	key.name=retain_string(system,key.name)
	system.instances[key]=instance
	success=true
	return true
}

@(private)
load_source :: proc(system: ^Audio_System, path: string) -> (rl.Sound,rl.Music,bool) {
	full_path := path
	joined_path: string
	defer if len(joined_path)>0 {delete(joined_path)}
	if !filepath.is_abs(full_path) {joined_path,_=filepath.join({system.root,path}); full_path=joined_path}
	path_cstring,_ := strings.clone_to_cstring(full_path)
	defer delete(path_cstring)
	if is_streaming_path(path) {
		music := rl.LoadMusicStream(path_cstring)
		return {},music,rl.IsMusicValid(music)
	}
	sound := rl.LoadSound(path_cstring)
	return sound,{},rl.IsSoundValid(sound)
}
