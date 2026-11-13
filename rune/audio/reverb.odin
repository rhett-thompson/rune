package audio

import "core:c"
import "core:mem"
import "core:sync"
import rl "vendor:raylib"

// raylib's stream processors have no userdata. Each callback identifies one
// native stream; its offset keeps multiple chunks aligned with the device block.
@(private) Reverb_Max_Sources :: 256
@(private) Reverb_Max_Block_Frames :: 16384

@(private)
Reverb_Source :: struct {
	stream: rl.AudioStream,
	bus: ^Bus_Reverb,
	gain_bits: u32,
	cycle: u64,
	offset: int,
}

@(private)
Bus_Reverb :: struct {
	target_bits, return_gain_bits: u32,
	wet: f32,
	room: Room_Reverb,
	input: [Reverb_Max_Block_Frames]f32,
}

@(private)
Reverb_State :: struct {
	sample_rate: int,
	cycle: u64,
	buses: [Bus]^Bus_Reverb,
	sources: [Reverb_Max_Sources]Reverb_Source,
	processors: [Reverb_Max_Sources]rl.AudioCallback,
	routes: map[rawptr]int,
}

// raylib has one device and a process-wide mixed callback. The owner thread
// installs and removes the callback, and the device thread owns DSP state.
@(private) device_reverb: ^Reverb_State

// Add a stereo room tail to a Rune bus. The send level is 0 through 1, and zero
// smoothly stops new input. The dry path and its existing gain are preserved.
// Call on the audio owner thread, as with the other Audio_System procedures.
set_bus_reverb :: proc(system: ^Audio_System, bus: Bus, wet: f32) -> bool {
	if system == nil || !valid_bus(bus) || !valid_gain(wet) {return false}
	if system.reverb == nil {
		if wet == 0 {return true}
		if !system.available || !rl.IsAudioDeviceReady() || sync.atomic_load(&device_reverb) != nil {return false}
		sample_rate := reverb_device_rate()
		if sample_rate == 0 {return false}
		state, err := mem.new(Reverb_State)
		if err != .None {return false}
		state.sample_rate = sample_rate
		state.routes = make(map[rawptr]int)
		init_reverb_processors(state, 0, Reverb_Max_Sources)
		if _, claimed := sync.atomic_compare_exchange_strong(&device_reverb, nil, state); !claimed {
			delete(state.routes)
			mem.free(state)
			return false
		}
		system.reverb = state
		rl.AttachAudioMixedProcessor(mix_reverb)
	}
	state := system.reverb
	effect := sync.atomic_load(&state.buses[bus])
	if effect == nil {
		if wet == 0 {return true}
		effect, err := mem.new(Bus_Reverb)
		if err != .None {return false}
		if !init_room_reverb(&effect.room, state.sample_rate) {
			mem.free(effect)
			return false
		}
		effect.target_bits = transmute(u32)wet
		effect.return_gain_bits = transmute(u32)bus_gain(&system.mixer, bus)
		sync.atomic_store(&state.buses[bus], effect)
		return true
	}
	sync.atomic_store(&effect.return_gain_bits, transmute(u32)bus_gain(&system.mixer, bus))
	sync.atomic_store(&effect.target_bits, transmute(u32)wet)
	return true
}

@(private)
reverb_device_rate :: proc() -> int {
	// Buffered Sounds are converted to raylib's actual device format at load.
	silence: [64]f32
	probe := rl.LoadSoundFromWave({frameCount = len(silence), sampleRate = 48000, sampleSize = 32, channels = 1, data = &silence})
	defer if probe.stream.buffer != nil {rl.UnloadSound(probe)}
	if !rl.IsSoundValid(probe) {return 0}
	if probe.channels != 2 || probe.sampleSize != 32 {return 0}
	return int(probe.sampleRate)
}

@(private)
update_reverb_gains :: proc(system: ^Audio_System) {
	if system.reverb == nil {return}
	for bus in Bus {
		if effect := system.reverb.buses[bus]; effect != nil {
			sync.atomic_store(&effect.return_gain_bits, transmute(u32)bus_gain(&system.mixer, bus))
		}
	}
}

@(private)
route_reverb_source :: proc(system: ^Audio_System, stream: rl.AudioStream, bus: Bus, gain: f32, starting: bool) {
	state := system.reverb
	if state == nil || stream.buffer == nil {return}
	effect: ^Bus_Reverb
	if valid_bus(bus) {effect = state.buses[bus]}
	if index, found := state.routes[stream.buffer]; found {
		source := &state.sources[index]
		if source.bus == effect {
			sync.atomic_store(&source.gain_bits, transmute(u32)gain)
			return
		}
		unroute_reverb_source(system, stream)
	}
	if effect == nil || (!starting && !rl.IsAudioStreamPlaying(stream)) {return}
	for &source, index in state.sources {
		if source.stream.buffer == nil {
			attach_reverb_source(state, index, stream, effect, gain)
			return
		}
	}
	// Reuse slots from finished voices when all slots have been assigned.
	for &source, index in state.sources {
		if !rl.IsAudioStreamPlaying(source.stream) {
			unroute_reverb_source(system, source.stream)
			attach_reverb_source(state, index, stream, effect, gain)
			return
		}
	}
}

@(private)
attach_reverb_source :: proc(state: ^Reverb_State, index: int, stream: rl.AudioStream, effect: ^Bus_Reverb, gain: f32) {
	state.sources[index] = {stream = stream, bus = effect, gain_bits = transmute(u32)gain}
	state.routes[stream.buffer] = index
	rl.AttachAudioStreamProcessor(stream, state.processors[index])
}

@(private)
unroute_reverb_source :: proc(system: ^Audio_System, stream: rl.AudioStream) {
	state := system.reverb
	if state == nil {return}
	if index, found := state.routes[stream.buffer]; found {
		// Detach waits for the device's current mix block before reusing the slot.
		rl.DetachAudioStreamProcessor(stream, state.processors[index])
		state.sources[index] = {}
		delete_key(&state.routes, stream.buffer)
	}
}

@(private)
shutdown_reverb :: proc(system: ^Audio_System) {
	state := system.reverb
	if state == nil {return}
	// All Rune streams are already detached and destroyed at this point.
	rl.DetachAudioMixedProcessor(mix_reverb)
	sync.atomic_store(&device_reverb, nil)
	for effect in state.buses {
		if effect == nil {continue}
		delete(effect.room.storage)
		mem.free(effect)
	}
	delete(state.routes)
	mem.free(state)
	system.reverb = nil
}

@(private)
init_reverb_processors :: proc(state: ^Reverb_State, $first: int, $count: int) {
	when count == 1 {
		state.processors[first] = reverb_source_processor(first)
	} else {
		half :: count / 2
		init_reverb_processors(state, first, half)
		init_reverb_processors(state, first + half, count - half)
	}
}

@(private)
reverb_source_processor :: proc($index: int) -> rl.AudioCallback {
	return proc "c" (data: rawptr, frames: c.uint) {
		state := sync.atomic_load(&device_reverb)
		collect_reverb_input(&state.sources[index], state.cycle, ([^][2]f32)(data)[:int(frames)])
	}
}

@(private)
collect_reverb_input :: proc "contextless" (source: ^Reverb_Source, cycle: u64, samples: [][2]f32) {
	if source.cycle != cycle {
		source.cycle = cycle
		source.offset = 0
	}
	gain := transmute(f32)sync.atomic_load(&source.gain_bits) * 0.5
	start := source.offset
	source.offset += len(samples)
	if gain == 0 || start >= Reverb_Max_Block_Frames {return}
	input := &source.bus.input
	for i in 0..<min(len(samples), Reverb_Max_Block_Frames - start) {
		input[start + i] += (samples[i][0] + samples[i][1]) * gain
	}
}

@(private)
mix_reverb :: proc "c" (data: rawptr, frames: c.uint) {
	state := sync.atomic_load(&device_reverb)
	output := ([^][2]f32)(data)[:int(frames)]
	for bus in Bus {
		if effect := sync.atomic_load(&state.buses[bus]); effect != nil {
			mix_reverb_bus(effect, output)
		}
	}
	state.cycle += 1
}

@(private)
mix_reverb_bus :: proc "contextless" (effect: ^Bus_Reverb, output: [][2]f32) {
	target := transmute(f32)sync.atomic_load(&effect.target_bits)
	return_gain := transmute(f32)sync.atomic_load(&effect.return_gain_bits)
	for &frame, i in output {
		effect.wet += effect.room.smoothing * (target - effect.wet)
		if abs(target - effect.wet) < 0.00001 {effect.wet = target}
		input: f32
		if i < Reverb_Max_Block_Frames {
			input, effect.input[i] = effect.input[i], 0
		}
		frame += room_reverb_sample(&effect.room, input * effect.wet) * return_gain
	}
}
