package input

import "core:math"
import rl "vendor:raylib"

// Activity describes this physical input sample, independently of mappings and
// modal capture. It does not choose a preferred device or change cursor policy.
Device_Activity :: struct {
	mouse_moved: bool,
	mouse_button_or_wheel: bool,
	gamepad: bool,
}

Device_Activity_Pad_Sample :: struct {
	available: bool,
	button_edge: bool,
	sticks: [4]f32,
}

Device_Activity_Sample :: struct {
	mouse_delta: [2]f32,
	mouse_wheel: [2]f32,
	mouse_button_edge: bool,
	pads: [4]Device_Activity_Pad_Sample,
}

Device_Activity_Pad_State :: struct {
	available: bool,
	// Last reported deflection, so slow deliberate movement accumulates while
	// small fluctuations around a stationary hold do not claim the device.
	sticks: [4]f32,
}

Device_Activity_State :: struct {
	pads: [4]Device_Activity_Pad_State,
}

Device_Activity_Stick_Deadzone :: f32(0.2)
Device_Activity_Stick_Change :: f32(0.05)

// Pure reducer for native sampling and synthetic tests. Connection alone sets
// a baseline; disconnect clears it without manufacturing a release gesture.
device_activity_tick :: proc(state: ^Device_Activity_State, sample: Device_Activity_Sample) -> Device_Activity {
	result := Device_Activity{
		mouse_moved = device_activity_nonzero(sample.mouse_delta),
		mouse_button_or_wheel = sample.mouse_button_edge || device_activity_nonzero(sample.mouse_wheel),
	}
	if state == nil {return result}
	for pad, index in sample.pads {
		previous := &state.pads[index]
		if !pad.available {previous^ = {}; continue}
		result.gamepad ||= pad.button_edge
		if !previous.available {
			previous.available = true
			for raw, axis in pad.sticks {
				if value, valid := device_activity_stick(raw); valid {previous.sticks[axis] = value}
			}
			continue
		}
		for raw, axis in pad.sticks {
			value, valid := device_activity_stick(raw)
			if !valid {continue}
			last := previous.sticks[axis]
			if (value == 0) != (last == 0) || abs(value-last) >= Device_Activity_Stick_Change {
				result.gamepad = true
				previous.sticks[axis] = value
			}
		}
	}
	return result
}

@(private)
device_activity_nonzero :: proc(value: [2]f32) -> bool {
	for component in value {
		if !math.is_nan(component) && !math.is_inf(component) && component != 0 {return true}
	}
	return false
}

@(private)
device_activity_stick :: proc(raw: f32) -> (value: f32, valid: bool) {
	if math.is_nan(raw) || math.is_inf(raw) {return 0, false}
	value = clamp(raw, -1, 1)
	if abs(value) <= Device_Activity_Stick_Deadzone {value = 0}
	return value, true
}

// Raylib has already polled the platform. These are bounded reads of its cached
// frame state, including pads used by UI navigation without mapped actions.
@(private)
sample_device_activity :: proc(input: ^Input, mouse_delta, mouse_wheel: rl.Vector2) {
	sample := Device_Activity_Sample{mouse_delta=mouse_delta, mouse_wheel=mouse_wheel}
	for button in rl.MouseButton {
		sample.mouse_button_edge ||= rl.IsMouseButtonPressed(button) || rl.IsMouseButtonReleased(button)
	}
	for index: i32 = 0; index < i32(len(sample.pads)); index += 1 {
		pad := &sample.pads[index]
		pad.available = rl.IsGamepadAvailable(index)
		if !pad.available {continue}
		for button in rl.GamepadButton {
			if button == .UNKNOWN {continue}
			pad.button_edge ||= rl.IsGamepadButtonPressed(index, button) || rl.IsGamepadButtonReleased(index, button)
		}
		// Logical trigger buttons above handle trigger activity. The signed
		// trigger axes can rest at -1 and must not count as displaced sticks.
		for axis in 0..<len(pad.sticks) {
			pad.sticks[axis] = rl.GetGamepadAxisMovement(index, rl.GamepadAxis(axis))
		}
	}
	input.activity = device_activity_tick(&input.activity_state, sample)
}
