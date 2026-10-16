package main

import "rune:audio"
import "rune:ecs"
import rl "vendor:raylib"

preload_test :: proc(system: ^audio.Audio_System, world: ^ecs.World, registry: ^ecs.Component_Registry) {
	entity := ecs.create_entity(world)
	defer {ecs.destroy_entity(world,entity); audio.update(system,world,0)}
	assert(ecs.add_component(world,registry,entity,"AudioPlayer",parse(`{
		"variants":{"clips":["examples/audio_components/assets/bell.wav","examples/asteroids/assets/thruster.wav"],"max_voices":3,"random_volume":0.1,"random_pitch":0.2},
		"stream":{"sound":"examples/asteroids/assets/music.mp3","looping":true},
		"mixed":{"clips":["examples/asteroids/assets/music.mp3","examples/audio_components/assets/bell.wav"],"max_voices":2},
		"missing":{"clips":["examples/audio_components/assets/bell.wav","examples/audio_components/assets/__missing_preload__.wav"]}
	}`)))
	assert(ecs.set_enabled(world,entity,false))
	rl.SetRandomSeed(12345)
	expected_random := rl.GetRandomValue(0,100000)
	rl.SetRandomSeed(12345)
	assert(audio.preload(system,world,entity,"variants"),"disabled emitters can preload before activation")
	assert(rl.GetRandomValue(0,100000)==expected_random,"preloading does not consume clip or variation randomness")
	key := ecs.Component_Instance{entity=entity,name="variants"}
	initial := system.instances[key]
	assert(len(initial.sources)==2 && len(initial.voices)==3,"every buffered variant and the bounded alias pool are ready")
	assert(!initial.started && initial.next_sequence==0 && !audio.is_playing(system,entity,"variants"),"preloading neither starts playback nor assigns voice sequence numbers")
	assert(audio.preload(system,world,entity,"variants"))
	assert(system.instances[key].voices[0].sound==initial.voices[0].sound,"repeated preload reuses existing aliases")
	assert(ecs.set_enabled(world,entity,true))
	// Select the longer bell clip so live-voice assertions have ample duration.
	for seed in 1..=100 {
		rl.SetRandomSeed(u32(seed))
		if rl.GetRandomValue(0,1)==0 {rl.SetRandomSeed(u32(seed)); break}
	}
	assert(audio.play(system,world,entity,"variants"))
	playing := system.instances[key]
	assert(playing.path=="examples/audio_components/assets/bell.wav")
	voice := playing.voices[0]
	assert(rl.IsSoundPlaying(voice.sound))
	assert(audio.preload(system,world,entity,"variants"))
	unchanged := system.instances[key]
	assert(rl.IsSoundPlaying(voice.sound) && unchanged.path==playing.path && unchanged.next_sequence==playing.next_sequence,"preloading a live player preserves its selected clip and playback")
	assert(unchanged.voices[0].sequence==voice.sequence && unchanged.voices[0].volume_offset==voice.volume_offset && unchanged.voices[0].pitch_offset==voice.pitch_offset,"voice variation and ordering remain unchanged")
	player,_ := ecs.get_audio_player(world,entity,"variants")
	reduced := player; reduced.max_voices=1
	assert(ecs.set_audio_player(world,entity,"variants",reduced))
	assert(audio.preload(system,world,entity,"variants"))
	assert(len(system.instances[key].voices)==3 && rl.IsSoundPlaying(voice.sound),"preloading never shrinks a pool containing active voices")
	broken := player; broken.clips=[]string{"examples/audio_components/assets/bell.wav","examples/audio_components/assets/__missing_preload__.wav"}
	assert(ecs.set_audio_player(world,entity,"variants",broken))
	assert(!audio.preload(system,world,entity,"variants"))
	assert(system.instances[key].path==playing.path && rl.IsSoundPlaying(voice.sound),"a failed configuration replacement preserves existing resources and playback")
	assert(!audio.preload(system,world,entity,"missing"))
	_, present := system.instances[ecs.Component_Instance{entity=entity,name="missing"}]
	assert(!present,"a failed first preload publishes no partial instance")
	replacement := player; replacement.clips=[]string{"examples/asteroids/assets/thruster.wav"}
	assert(ecs.set_audio_player(world,entity,"variants",replacement))
	assert(audio.preload(system,world,entity,"variants"))
	reloaded := system.instances[key]
	assert(len(reloaded.sources)==1 && len(reloaded.voices)==3 && !reloaded.started && reloaded.next_sequence==0,"a successful changed configuration replaces its cached sources and voice pool without playing")
	assert(audio.preload(system,world,entity,"stream"))
	stream_key := ecs.Component_Instance{entity=entity,name="stream"}
	stream := system.instances[stream_key]
	assert(stream.streaming && !stream.started && !audio.is_playing(system,entity,"stream"))
	assert(audio.play(system,world,entity,"stream"))
	assert(audio.preload(system,world,entity,"stream"))
	assert(system.instances[stream_key].music==stream.music && audio.is_playing(system,entity,"stream"),"preloading an existing stream preserves its playback channel")
	assert(audio.preload(system,world,entity,"mixed"))
	mixed_key := ecs.Component_Instance{entity=entity,name="mixed"}
	mixed := system.instances[mixed_key]
	assert(mixed.streaming && len(mixed.sources)==1 && len(mixed.voices)==2,"mixed configurations preload buffered variants beside their single stream")
	assert(!audio.preload(system,world,entity,"unknown"))
	assert(!audio.preload(nil,world,entity,"variants"))
}
