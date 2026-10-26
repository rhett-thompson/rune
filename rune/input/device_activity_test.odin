package input

import "core:math"
import "core:testing"

@(test)
device_activity_stick_gestures_survive_holds_noise_and_device_changes :: proc(t: ^testing.T) {
	state: Device_Activity_State
	sample: Device_Activity_Sample
	sample.pads[0] = {available=true, sticks={0.7,0,0,0}}
	testing.expect(t, !device_activity_tick(&state,sample).gamepad, "connecting an already deflected controller only establishes its baseline")
	testing.expect(t, !device_activity_tick(&state,sample).gamepad, "stationary holds do not take the pointer back from a mouse")
	sample.pads[0].sticks[0] = 0
	testing.expect(t, device_activity_tick(&state,sample).gamepad, "returning a stick to neutral is a real gesture")
	for drift in ([3]f32{0.1,-0.19,0.2}) {
		sample.pads[0].sticks[0] = drift
		testing.expect(t, !device_activity_tick(&state,sample).gamepad, "neutral drift never claims the device")
	}
	sample.pads[0].sticks[0] = 0.6
	testing.expect(t, device_activity_tick(&state,sample).gamepad, "leaving the deadzone reports a gesture")
	for deflection in ([3]f32{0.61,0.63,0.64}) {
		sample.pads[0].sticks[0] = deflection
		testing.expect(t, !device_activity_tick(&state,sample).gamepad, "small hold fluctuations do not repeatedly hide the pointer")
	}
	sample.pads[0].sticks[0] = 0.67
	testing.expect(t, device_activity_tick(&state,sample).gamepad, "slow deliberate changes accumulate from the last reported deflection")
	sample.pads[0].sticks[0] = math.nan_f32()
	testing.expect(t, !device_activity_tick(&state,sample).gamepad, "invalid samples do not manufacture neutral crossings")
	sample.pads[0].sticks[0] = 0.67
	testing.expect(t, !device_activity_tick(&state,sample).gamepad, "a recovered sample retains its prior baseline")
	sample.pads[3].available = true
	testing.expect(t, !device_activity_tick(&state,sample).gamepad, "an idle second controller does not replace the active device")
	sample.pads[3].sticks[3] = -0.8
	testing.expect(t, device_activity_tick(&state,sample).gamepad, "each pad and both sticks have independent gesture history")
	sample.pads[3] = {}
	testing.expect(t, !device_activity_tick(&state,sample).gamepad, "unplugging a held controller is not user input")
	sample.pads[3] = {available=true, sticks={0,0,0,-0.8}}
	testing.expect(t, !device_activity_tick(&state,sample).gamepad, "reconnection starts a fresh baseline")
}

@(test)
device_activity_mouse_and_button_edges_remain_independent_of_capture :: proc(t: ^testing.T) {
	controls := Input{captured=true}
	sample := Device_Activity_Sample{mouse_delta={2,-1},mouse_wheel={1,0},mouse_button_edge=true}
	sample.pads[2] = {available=true,button_edge=true}
	controls.activity = device_activity_tick(&controls.activity_state,sample)
	testing.expect(t, controls.captured && controls.activity==Device_Activity{mouse_moved=true,mouse_button_or_wheel=true,gamepad=true},
		"activity reports all simultaneous devices without modal capture or mappings choosing a winner")
	sample.mouse_delta = {}
	sample.mouse_wheel = {}
	sample.mouse_button_edge = false
	sample.pads[2].button_edge = false
	controls.activity = device_activity_tick(&controls.activity_state,sample)
	testing.expect(t, controls.activity==Device_Activity{}, "a held button with no edge does not repeatedly claim gamepad activity")
	sample.pads[2].button_edge = true
	testing.expect(t, device_activity_tick(&controls.activity_state,sample).gamepad, "real button releases as well as presses can report their edge")
	sample.pads[2].available = false
	testing.expect(t, !device_activity_tick(&controls.activity_state,sample).gamepad, "unavailable devices cannot report stale button edges")
	sample.mouse_delta = {math.inf_f32(1),math.nan_f32()}
	sample.mouse_wheel = {0,-2}
	testing.expect(t, device_activity_tick(&controls.activity_state,sample)==Device_Activity{mouse_button_or_wheel=true},
		"invalid pointer deltas are ignored while either wheel direction still reports activity")
	sample.mouse_wheel = {}
	sample.mouse_button_edge = true
	testing.expect(t, device_activity_tick(&controls.activity_state,sample)==Device_Activity{mouse_button_or_wheel=true},
		"a stationary click or release restores pointer use without movement")
}
