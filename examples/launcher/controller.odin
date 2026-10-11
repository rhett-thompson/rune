package main

Pad_Action_State :: struct {sample_ready, launch_ready, cancel_ready: bool}

// InitWindow resets raylib's prior button samples. Require a released sample
// after opening/focusing the launcher before accepting a new A or B edge, so
// holding an example's Quit button cannot relaunch or close the launcher.
pad_actions_update :: proc(state: ^Pad_Action_State, a_down, b_down, a_pressed, b_pressed: bool) -> (launch, cancel: bool) {
	// The first iteration after InitWindow precedes EndDrawing's input poll.
	// Its zeroed button state is not evidence that a held button was released.
	if !state.sample_ready {state.sample_ready = true; return false, false}
	if !a_down {state.launch_ready = true}
	if !b_down {state.cancel_ready = true}
	launch = state.launch_ready && a_pressed
	cancel = state.cancel_ready && b_pressed
	if launch {state.launch_ready = false}
	if cancel {state.cancel_ready = false}
	return
}
