package audio

import "core:encoding/json"
import "core:mem"
import "core:testing"
import "rune:ecs"

// No native audio device is needed to verify ownership of retained resources.
rebind_test_system :: proc() -> Audio_System {
	arena, _ := mem.new(mem.Dynamic_Arena)
	assert(arena != nil)
	mem.dynamic_arena_init(arena)
	return {available=true,arena=arena,instances=make(map[ecs.Component_Instance]Audio_Instance),
		retained_strings=make(map[string]string),mixer=default_mixer()}
}

rebind_test_destroy_system :: proc(system: ^Audio_System) {
	// Test instances contain sentinel handles, so release only CPU test storage.
	delete(system.instances)
	delete(system.retained_strings)
	mem.dynamic_arena_destroy(system.arena)
	mem.free(system.arena)
}

rebind_test_player :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, source: string) -> ecs.Entity {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)source,&value,allocator=context.temp_allocator)==nil)
	entity := ecs.create_entity(world)
	assert(ecs.add_component(world,registry,entity,"AudioPlayer",value))
	return entity
}

@(test)
audio_rebind_preserves_resources_and_fades_after_world_destruction :: proc(t: ^testing.T) {
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	previous := ecs.init()
	old_owner := ecs.create_entity(&previous)
	ecs.destroy(&previous)
	next := ecs.init(); defer ecs.destroy(&next)
	owner := rebind_test_player(&next,&registry,`{"theme":{"clips":["a.ogg","b.ogg"],"bus":"music","volume":0.25}}`)
	system := rebind_test_system(); defer rebind_test_destroy_system(&system)
	assert(set_bus_volume(&system.mixer,.music,0.5))
	assert(fade_bus(&system.mixer,.music,0,2))
	update_mixer(&system.mixer,0.25)
	mixer_before := system.mixer
	decoder_sentinel: int
	clips := []string{"a.ogg","b.ogg"}
	source := ecs.Component_Instance{entity=old_owner,name="music"}
	system.instances[source] = Audio_Instance{
		configured_clips=clips,path="b.ogg",streaming=true,started=true,
		music={ctxData=&decoder_sentinel,frameCount=98765,looping=true},
		stop_requested=true,stop_fading=true,stop_fade_duration=2,stop_fade_elapsed=0.4,
		volume=0.2,pitch=0.9,pan=0.1,volume_offset=0.03,pitch_offset=-0.1,
		suspended=true,resume_stream=true,next_sequence=7,
	}
	testing.expect(t,rebind(&system,&next,old_owner,"music",owner,"theme"),"a destroyed source World does not invalidate the audio system's retained playback")
	destination := ecs.Component_Instance{entity=owner,name="theme"}
	transferred, found := system.instances[destination]
	_, source_present := system.instances[source]
	testing.expect(t,found && !source_present && len(system.instances)==1,"ownership moves once and the old key is removed")
	testing.expect(t,transferred.music.ctxData==&decoder_sentinel && transferred.music.frameCount==98765 &&
		raw_data(transferred.configured_clips)==raw_data(clips) && transferred.path=="b.ogg","the decoder and selected clip retain their original storage")
	testing.expect(t,transferred.started && transferred.streaming && transferred.suspended && transferred.resume_stream &&
		transferred.stop_requested && transferred.stop_fading && transferred.stop_fade_duration==2 && transferred.stop_fade_elapsed==0.4 &&
		transferred.volume==0.2 && transferred.pitch_offset==-0.1 && transferred.next_sequence==7,"playback, suspension, variation and pending stop progress remain intact")
	testing.expect(t,system.mixer==mixer_before,"rebinding never modifies bus gains or fades")
	remove_missing_instances(&system,&next)
	testing.expect(t,len(system.instances)==1,"ordinary destination cleanup retains the moved player")
	testing.expect(t,rebind(&system,&next,owner,"theme",owner,"theme") && len(system.instances)==1,"rebinding to the same live key is idempotent")
}

@(test)
audio_rebind_rejects_incompatible_or_occupied_destinations_atomically :: proc(t: ^testing.T) {
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w := ecs.init(); defer ecs.destroy(&w)
	owner := rebind_test_player(&w,&registry,`{"theme":{"sound":"theme.ogg"}}`)
	source_owner := ecs.create_entity(&w)
	source := ecs.Component_Instance{entity=source_owner,name="music"}
	destination := ecs.Component_Instance{entity=owner,name="theme"}
	system := rebind_test_system(); defer rebind_test_destroy_system(&system)
	system.instances[source]={configured_sound="other.ogg",started=true,next_sequence=17}
	testing.expect(t,!rebind(&system,&w,source_owner,"music",owner,"theme") && len(system.instances)==1,"different sources leave the original playback untouched")
	system.instances[source]={configured_sound="theme.ogg",started=true,next_sequence=17}
	system.instances[destination]={configured_sound="theme.ogg",next_sequence=33}
	testing.expect(t,!rebind(&system,&w,source_owner,"music",owner,"theme") && len(system.instances)==2 &&
		system.instances[source].next_sequence==17 && system.instances[destination].next_sequence==33,"occupied destinations are never released or overwritten")
	delete_key(&system.instances,destination)
	testing.expect(t,!rebind(&system,&w,source_owner,"missing",owner,"theme") &&
		!rebind(&system,&w,source_owner,"music",owner,"missing") && len(system.instances)==1,"missing instances preserve the source")
	testing.expect(t,!rebind(nil,&w,source_owner,"music",owner,"theme") &&
		!rebind(&system,nil,source_owner,"music",owner,"theme"),"invalid owners fail safely")
	system.available=false
	testing.expect(t,!rebind(&system,&w,source_owner,"music",owner,"theme") && len(system.instances)==1)
	system.available=true
	ecs.destroy_entity(&w,owner)
	testing.expect(t,!rebind(&system,&w,source_owner,"music",owner,"theme") && len(system.instances)==1,"stale destination handles cannot claim playback")
}
