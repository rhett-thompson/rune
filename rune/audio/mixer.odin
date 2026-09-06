package audio

import "core:math"
import "rune:ecs"

Bus :: ecs.Audio_Bus
Bus_State :: struct {
	volume: f32,
	muted: bool,
	start, target, elapsed, duration: f32,
}
Mixer :: struct {buses: [Bus]Bus_State}

default_mixer :: proc() -> Mixer {
	result: Mixer
	for &bus in result.buses {bus.volume = 1}
	return result
}

set_bus_volume :: proc(mixer: ^Mixer, bus: Bus, volume: f32) -> bool {
	if mixer == nil || !valid_bus(bus) || !valid_gain(volume) {return false}
	mixer.buses[bus].volume = volume
	mixer.buses[bus].duration = 0
	return true
}

mute_bus :: proc(mixer: ^Mixer, bus: Bus, muted: bool) -> bool {
	if mixer == nil || !valid_bus(bus) {return false}
	mixer.buses[bus].muted = muted
	return true
}

// A new fade starts at the current volume. Muting does not discard a fade.
fade_bus :: proc(mixer: ^Mixer, bus: Bus, volume, seconds: f32) -> bool {
	if mixer == nil || !valid_bus(bus) || !valid_gain(volume) ||
		seconds < 0 || math.is_nan(seconds) || math.is_inf(seconds) {return false}
	if seconds == 0 {return set_bus_volume(mixer,bus,volume)}
	state := &mixer.buses[bus]
	state.start, state.target, state.elapsed, state.duration = state.volume, volume, 0, seconds
	return true
}

update_mixer :: proc(mixer: ^Mixer, dt: f32) {
	if mixer == nil || dt <= 0 || math.is_nan(dt) || math.is_inf(dt) {return}
	for &bus in mixer.buses {
		if bus.duration <= 0 {continue}
		bus.elapsed = min(bus.duration, bus.elapsed+dt)
		bus.volume = bus.start+(bus.target-bus.start)*(bus.elapsed/bus.duration)
		if bus.elapsed == bus.duration {bus.volume = bus.target; bus.duration = 0}
	}
}

bus_gain :: proc(mixer: ^Mixer, bus: Bus) -> f32 {
	if mixer == nil || !valid_bus(bus) {return 0}
	master := mixer.buses[.master]
	channel := mixer.buses[bus]
	if master.muted || channel.muted {return 0}
	return master.volume if bus == .master else master.volume*channel.volume
}

@(private)
valid_bus :: proc(bus: Bus) -> bool {return bus >= .master && bus <= .ui}
@(private)
valid_gain :: proc(value: f32) -> bool {return value >= 0 && value <= 1 && !math.is_nan(value)}
