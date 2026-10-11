package input

import "core:encoding/json"
import "core:math"
import "core:mem"

// Serialize only the fields defined for each binding/axis variant. Reflection
// on Binding/Axis cannot infer which zero values belong to another variant.
mappings_document :: proc(input: ^Input, allocator: mem.Allocator) -> json.Object {
	document := make(json.Object, allocator)
	if input.has_schema {document["$schema"] = input.schema}
	actions := make(json.Object, allocator)
	for name, bindings in input.mappings.actions {
		array := make(json.Array, 0, len(bindings), allocator)
		for binding in bindings {
			object := make(json.Object, allocator)
			object["type"] = binding.type
			switch binding.type {
			case "keyboard": object["key"] = binding.key
			case "mouse_button": object["button"] = binding.button
			case "gamepad_button":
				object["button"] = binding.button
				if binding.gamepad != 0 {object["gamepad"] = json.Integer(binding.gamepad)}
			}
			append(&array, object)
		}
		actions[name] = array
	}
	axes := make(json.Object, allocator)
	for name, axis in input.mappings.axes {
		object := make(json.Object, allocator)
		if axis.type == "" {
			object["negative"] = axis.negative
			object["positive"] = axis.positive
		} else {
			object["type"] = axis.type
			if axis.type != "mouse_wheel" {object["axis"] = axis.axis}
			if axis.scale != 0 {object["scale"] = axis_scale_json(axis.scale)}
			if axis.type == "gamepad_axis" {
				if axis.gamepad != 0 {object["gamepad"] = json.Integer(axis.gamepad)}
				if axis.deadzone != 0 {object["deadzone"] = json.Float(axis.deadzone)}
			}
		}
		if axis.invert {object["invert"] = true}
		axes[name] = object
	}
	document["actions"] = actions
	document["axes"] = axes
	return document
}

axis_scale_json :: proc(value: f32) -> json.Value {
	wide := f64(value)
	if wide >= -9223372036854775808 && wide < 9223372036854775808 && math.floor(wide) == wide {
		return json.Integer(value)
	}
	return json.Float(value)
}
