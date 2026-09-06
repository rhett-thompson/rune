package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "rune:audio"
import "rune:ecs"
import "rune:scene"

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
	assert(ecs.remove_component_instance(&world,entity,"AudioPlayer","bell"))
	audio.update(&system,&world,0.5)
	assert(len(system.instances)==0)
}
