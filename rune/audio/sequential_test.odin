package audio

import "core:encoding/json"
import "core:testing"
import "core:time"
import "rune:ecs"
import rl "vendor:raylib"

@(test)
audio_sequential_configuration_is_opt_in :: proc(t: ^testing.T) {
	testing.expect(t, !ecs.default_audio_player().sequential)
	for source, index in ([3]string{
		`{"clips":["a.ogg","b.ogg"]}`,
		`{"clips":["a.ogg","b.ogg"],"sequential":true}`,
		`{"clips":["a.ogg","b.ogg"],"sequential":"true"}`,
	}) {
		data: json.Value
		assert(json.unmarshal(transmute([]u8)source, &data, allocator=context.temp_allocator) == nil)
		player, ok := ecs.audio_player_from_json(data)
		testing.expect(t, ok == (index != 2) && player.sequential == (index == 1))
	}
}

when #config(RUNE_SEQUENTIAL_AUDIO_RUNTIME_TEST, false) {
	sequential_test_wait_for_clip :: proc(
		system: ^Audio_System, world: ^ecs.World, key: ecs.Component_Instance, index: int, playing: bool = true,
	) -> bool {
		for _ in 0..<250 {
			update(system, world, 0.01)
			if system.instances[key].clip_index == index && is_playing(system, key.entity, key.name) == playing {
				return true
			}
			time.sleep(10*time.Millisecond)
		}
		return false
	}

	@(test)
	audio_sequential_streams_advance_wrap_and_resume :: proc(t: ^testing.T) {
		registry := ecs.init_registry(); defer ecs.destroy_registry(&registry)
		assert(ecs.register_builtin_components(&registry))
		world := ecs.init(); defer ecs.destroy(&world)
		system := init("."); defer shutdown(&system)
		if !system.available {testing.fail_now(t, "Sequential audio runtime validation requires an audio device")}
		previous_volume := rl.GetMasterVolume()
		rl.SetMasterVolume(0)
		defer rl.SetMasterVolume(previous_volume)

		// These two short streams let the real audio device reach natural EOF.
		first :: "examples/dungeoncrawler/assets/sounds/potion.mp3"
		second :: "examples/dungeoncrawler/assets/sounds/hit_2.mp3"
		loop_owner := rebind_test_player(&world, &registry, `{"music":{"clips":["` + first + `","` + second + `"],"sequential":true,"looping":true,"bus":"music"}}`)
		loop_key := ecs.Component_Instance{entity=loop_owner, name="music"}
		if !testing.expect(t, play(&system, &world, loop_owner, loop_key.name, 0.25)) {return}
		testing.expect(t, system.instances[loop_key].path == first, "Explicit play starts with the first clip")
		if !testing.expect(t, sequential_test_wait_for_clip(&system, &world, loop_key, 1), "Natural EOF advances to the second clip") {return}
		playing := system.instances[loop_key]
		testing.expect(t, playing.path == second && playing.playback_gain == 0.25, "Advancing preserves the track gain")

		for _ in 0..<10 {update(&system, &world, 0.01); time.sleep(10*time.Millisecond)}
		if !testing.expect(t, pause_stream(&system, loop_owner, loop_key.name)) {return}
		paused_cursor := rl.GetMusicTimePlayed(playing.music)
		for _ in 0..<5 {update(&system, &world, 0.01); time.sleep(10*time.Millisecond)}
		testing.expect(t, paused_cursor > 0 && rl.GetMusicTimePlayed(playing.music) == paused_cursor &&
			system.instances[loop_key].clip_index == 1 && !is_playing(&system, loop_owner, loop_key.name),
			"Pausing retains the second clip and its cursor")
		if !testing.expect(t, resume_stream(&system, &world, loop_owner, loop_key.name, 0.4)) {return}
		resumed := system.instances[loop_key]
		testing.expect(t, resumed.clip_index == 1 && resumed.music.stream.buffer == playing.music.stream.buffer &&
			rl.GetMusicTimePlayed(resumed.music) >= paused_cursor && resumed.playback_gain == 0.4,
			"Resuming keeps the decoder and applies the incoming gain")

		if !testing.expect(t, sequential_test_wait_for_clip(&system, &world, loop_key, 0), "The looping list wraps to the first clip") {return}
		testing.expect(t, system.instances[loop_key].path == first && system.instances[loop_key].playback_gain == 0.4)
		if !testing.expect(t, sequential_test_wait_for_clip(&system, &world, loop_key, 1)) {return}
		testing.expect(t, play(&system, &world, loop_owner, loop_key.name) && system.instances[loop_key].path == first,
			"An explicit replay starts the list over")

		// Simulate EOF just before the game's frame callback can request a pause.
		rl.StopMusicStream(system.instances[loop_key].music)
		testing.expect(t, is_playing(&system, loop_owner, loop_key.name), "The sequence stays active until update advances it")
		if !testing.expect(t, pause_stream(&system, loop_owner, loop_key.name)) {return}
		update(&system, &world)
		testing.expect(t, system.instances[loop_key].clip_index == 0, "Pausing at EOF holds the pending transition")
		if !testing.expect(t, resume_stream(&system, &world, loop_owner, loop_key.name)) {return}
		update(&system, &world)
		testing.expect(t, system.instances[loop_key].clip_index == 1, "Resuming at EOF advances to the next clip")
		assert(stop(&system, loop_owner, loop_key.name))

		buffered :: "examples/audio_components/assets/bell.wav"
		once_owner := rebind_test_player(&world, &registry, `{"music":{"clips":["` + first + `","` + buffered + `","` + second + `"],"sequential":true,"play_on_start":true}}`)
		once_key := ecs.Component_Instance{entity=once_owner, name="music"}
		update(&system, &world)
		testing.expect(t, system.instances[once_key].path == first && is_playing(&system, once_owner, once_key.name),
			"Autoplay starts with the first clip")
		if !testing.expect(t, sequential_test_wait_for_clip(&system, &world, once_key, 1)) {return}
		testing.expect(t, system.instances[once_key].path == buffered && !system.instances[once_key].streaming,
			"A sequence can switch from a stream to a buffered clip")
		if !testing.expect(t, sequential_test_wait_for_clip(&system, &world, once_key, 2)) {return}
		testing.expect(t, system.instances[once_key].path == second && system.instances[once_key].streaming)
		testing.expect(t, sequential_test_wait_for_clip(&system, &world, once_key, 2, false), "A nonlooping list stops after the last clip")
		update(&system, &world)
		testing.expect(t, !is_playing(&system, once_owner, once_key.name), "A completed autoplay list stays stopped")
	}
}
