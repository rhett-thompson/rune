package audio

import rl "vendor:raylib"

// One retained alias per distinct clip in an instance keeps the decoded
// source alive for the instance's base playback and all its overlapping voices.
@(private)
acquire_buffered_sound :: proc(system: ^Audio_System, path: string) -> (rl.Sound, bool) {
	source, cached := system.buffered_sources[path]
	if !cached {
		sound, _, loaded := load_source(system, path, false)
		if !loaded {return {}, false}
		source.sound = sound
	}
	alias := rl.LoadSoundAlias(source.sound)
	if !rl.IsSoundValid(alias) {
		if !cached {rl.UnloadSound(source.sound)}
		return {}, false
	}
	source.references += 1
	system.buffered_sources[retain_string(system, path)] = source
	return alias, true
}

// Create voice aliases directly from the owning buffer. Each voice has its
// own stream state and is released before the instance's clip references.
@(private)
buffered_voice :: proc(system: ^Audio_System, path: string) -> rl.Sound {
	return rl.LoadSoundAlias(system.buffered_sources[path].sound)
}

@(private)
release_buffered_sound :: proc(system: ^Audio_System, path: string, alias: rl.Sound) {
	unroute_reverb_source(system, alias.stream)
	rl.UnloadSoundAlias(alias)
	source := system.buffered_sources[path]
	assert(source.references > 0)
	if source.references == 1 {
		rl.UnloadSound(source.sound)
		delete_key(&system.buffered_sources, path)
	} else {
		source.references -= 1
		system.buffered_sources[path] = source
	}
}
