package input

// JSON input mappings will resolve action names to these runtime values.
Action_State :: struct {
	is_down:      bool,
	pressed:      bool,
	released:     bool,
	strength:     f32,
}
