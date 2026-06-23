package jsonutil

import "core:encoding/json"

// number converts the JSON numeric types used by scene and component data to
// f32. Callers retain responsibility for field-specific range validation.
number :: proc(value: json.Value) -> (f32, bool) {
	#partial switch numeric_value in value {
	case json.Integer: return f32(numeric_value), true
	case json.Float:   return f32(numeric_value), true
	}
	return 0, false
}
