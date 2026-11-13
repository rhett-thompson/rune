package audio

import "core:testing"

@(test)
reverb_send_validation :: proc(t: ^testing.T) {
	system := Audio_System{mixer = default_mixer()}
	testing.expect(t, set_bus_reverb(&system, .sfx, 0), "A dry request needs no audio device or allocation")
	testing.expect(t, !set_bus_reverb(&system, .sfx, 0.5), "A live reverb needs an audio device")
	testing.expect(t, !set_bus_reverb(&system, .sfx, -0.1) && !set_bus_reverb(&system, .sfx, 1.1))
	testing.expect(t, !set_bus_reverb(&system, Bus(255), 0))
	testing.expect(t, system.reverb == nil)
}

@(test)
reverb_aligns_source_chunks :: proc(t: ^testing.T) {
	bus: Bus_Reverb
	first := Reverb_Source{bus = &bus, gain_bits = transmute(u32)f32(0.5)}
	second := Reverb_Source{bus = &bus, gain_bits = transmute(u32)f32(1)}
	collect_reverb_input(&first, 1, [][2]f32{{1, 3}, {3, 5}})
	collect_reverb_input(&first, 1, [][2]f32{{5, 7}})
	collect_reverb_input(&second, 1, [][2]f32{{1, 3}})
	testing.expect(t, bus.input[0] == 3 && bus.input[1] == 2 && bus.input[2] == 3,
		"Each stream starts at the device block's first frame and keeps its own offset")
	collect_reverb_input(&first, 2, [][2]f32{{3, 5}})
	testing.expect(t, bus.input[0] == 5 && bus.input[1] == 2,
		"A new device block resets a stream's offset")
}

@(test)
reverb_returns_stereo_tail_with_bus_gain :: proc(t: ^testing.T) {
	bus := Bus_Reverb{return_gain_bits = transmute(u32)f32(1)}
	assert(init_room_reverb(&bus.room, 44100))
	defer delete(bus.room.storage)
	dry: [1024][2]f32
	dry[0] = {0.25, -0.25}
	bus.input[0] = 1
	mix_reverb_bus(&bus, dry[:])
	testing.expect(t, dry[0] == [2]f32{0.25, -0.25} && dry[1000] == [2]f32{}, "Zero send preserves dry samples")
	testing.expect(t, bus.input[0] == 0, "The device block consumes the send buffer")

	bus.target_bits = transmute(u32)f32(1)
	bus.wet = 1
	bus.input[0] = 1
	start: [512][2]f32
	mix_reverb_bus(&bus, start[:])
	testing.expect(t, start[0] == [2]f32{}, "The send does not add a second direct copy")

	bus.target_bits = 0
	tail: [4096][2]f32
	mix_reverb_bus(&bus, tail[:])
	stereo, has_tail := false, false
	for frame in tail {
		stereo |= frame[0] != frame[1]
		has_tail |= abs(frame[0]) > 0.0001 || abs(frame[1]) > 0.0001
	}
	testing.expect(t, stereo && has_tail, "The stereo return continues after the source and send stop")
	testing.expect(t, bus.wet > 0 && bus.wet < 1, "A send change smooths over consecutive frames")

	bus.return_gain_bits = 0
	muted: [1024][2]f32
	mix_reverb_bus(&bus, muted[:])
	testing.expect(t, muted == [1024][2]f32{}, "A muted bus silences its return immediately")
}
