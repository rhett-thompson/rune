package input

import "core:encoding/json"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

@(private="file")
temporary_input_path :: proc(t: ^testing.T) -> string {
	file, err := os.create_temp_file("", "rune-input-*.json")
	if !testing.expect(t, err == nil) {return ""}
	path, _ := strings.clone(os.name(file))
	testing.expect(t, os.close(file) == nil)
	return path
}

@(test)
save_preserves_schema_rebindings_and_type_specific_fields :: proc(t: ^testing.T) {
	path := temporary_input_path(t)
	if path == "" {return}
	defer delete(path)
	defer os.remove(path)
	document :: `{
		"$schema": "../../schemas/input.schema.json",
		"actions": {
			"fire": [
				{"type":"keyboard","key":"F","gamepad":0},
				{"type":"mouse_button","button":"LEFT"},
				{"type":"gamepad_button","button":"RIGHT_TRIGGER","gamepad":1},
				{"type":"gamepad_button","button":"LEFT_TRIGGER","gamepad":0}
			],
			"left":[{"type":"keyboard","key":"A"}],
			"right":[{"type":"keyboard","key":"D"}]
		},
		"axes": {
			"horizontal":{"negative":"left","positive":"right","invert":true},
			"mouse":{"type":"mouse_delta","axis":"x","scale":2,"gamepad":0},
			"wheel":{"type":"mouse_wheel","scale":-2},
			"stick":{"type":"gamepad_axis","axis":"RIGHT_Y","gamepad":1,"deadzone":0.15,"scale":0.5,"invert":true}
		}
	}`
	if !testing.expect(t, os.write_entire_file(path, string(document)) == nil) {return}
	controls, loaded := load(path)
	if !testing.expect(t, loaded) {return}
	defer destroy(&controls)
	testing.expect(t, rebind_keyboard(&controls, "fire", "G"))
	if !testing.expect(t, save(&controls)) {return}
	data, read_error := os.read_entire_file(path, context.allocator)
	if !testing.expect(t, read_error == nil) {return}
	defer delete(data)
	value: json.Value
	if !testing.expect(t, json.unmarshal(data, &value) == nil) {return}
	defer json.destroy_value(value)
	object := value.(json.Object)
	testing.expect(t, object["$schema"].(json.String) == "../../schemas/input.schema.json")
	testing.expect(t, len(object) == 3)
	fire := object["actions"].(json.Object)["fire"].(json.Array)
	keyboard := fire[0].(json.Object)
	testing.expect(t, len(keyboard) == 2 && keyboard["key"].(json.String) == "G", "keyboard output has no gamepad or button fields")
	testing.expect(t, len(fire[1].(json.Object)) == 2, "mouse output has only type and button")
	pad_one := fire[2].(json.Object)
	testing.expect(t, len(pad_one) == 3 && pad_one["gamepad"].(json.Integer) == 1)
	testing.expect(t, len(fire[3].(json.Object)) == 2, "default pad index is omitted")
	axes := object["axes"].(json.Object)
	testing.expect(t, len(axes["horizontal"].(json.Object)) == 3)
	mouse := axes["mouse"].(json.Object)
	scale, integral := mouse["scale"].(json.Integer)
	testing.expect(t, len(mouse) == 3 && integral && scale == 2, "integral scale uses a JSON integer")
	wheel := axes["wheel"].(json.Object)
	testing.expect(t, len(wheel) == 2 && wheel["scale"].(json.Integer) == -2)
	testing.expect(t, len(axes["stick"].(json.Object)) == 6)
	reloaded, reload_ok := load(path)
	if !testing.expect(t, reload_ok) {return}
	defer destroy(&reloaded)
	key, key_found := keyboard_binding(&reloaded, "fire")
	testing.expect(t, key_found && key == "G")
	testing.expect(t, reloaded.mappings.actions["fire"][2].button == "RIGHT_TRIGGER" && reloaded.mappings.actions["fire"][2].gamepad == 1)
	testing.expect(t, reloaded.mappings.actions["fire"][3].button == "LEFT_TRIGGER")
	testing.expect(t, reloaded.mappings.axes["stick"] == controls.mappings.axes["stick"])
	testing.expect(t, reloaded.mappings.axes["horizontal"] == controls.mappings.axes["horizontal"])
	if !testing.expect(t, save(&reloaded)) {return}
	second, second_error := os.read_entire_file(path, context.allocator)
	if !testing.expect(t, second_error == nil) {return}
	defer delete(second)
	testing.expect(t, string(data) == string(second), "canonical save is stable across a load/save round trip")
}

@(test)
save_preserves_schema_presence_and_omits_axis_defaults :: proc(t: ^testing.T) {
	path := temporary_input_path(t)
	if path == "" {return}
	defer delete(path)
	defer os.remove(path)
	for document in ([2]string{
		`{"actions":{},"axes":{"wheel":{"type":"mouse_wheel"},"stick":{"type":"gamepad_axis","axis":"LEFT_X"}}}`,
		`{"$schema":"","actions":{},"axes":{"wheel":{"type":"mouse_wheel"},"stick":{"type":"gamepad_axis","axis":"LEFT_X"}}}`,
	}) {
		if !testing.expect(t, os.write_entire_file(path, document) == nil) {return}
		controls, loaded := load(path)
		if !testing.expect(t, loaded) {return}
		defer destroy(&controls)
		if !testing.expect(t, save(&controls)) {return}
		data, err := os.read_entire_file(path, context.allocator)
		if !testing.expect(t, err == nil) {return}
		defer delete(data)
		value: json.Value
		if !testing.expect(t, json.unmarshal(data, &value) == nil) {return}
		defer json.destroy_value(value)
		object := value.(json.Object)
		_, schema_present := object["$schema"]
		testing.expect(t, schema_present == controls.has_schema, "even an empty schema string retains its presence")
		testing.expect(t, len(object["axes"].(json.Object)["wheel"].(json.Object)) == 1)
		testing.expect(t, len(object["axes"].(json.Object)["stick"].(json.Object)) == 2)
	}
}

@(test)
save_rejects_invalid_mappings_without_overwriting :: proc(t: ^testing.T) {
	path := temporary_input_path(t)
	if path == "" {return}
	defer delete(path)
	defer os.remove(path)
	document :: `{"actions":{},"axes":{"wheel":{"type":"mouse_wheel","scale":1}}}`
	if !testing.expect(t, os.write_entire_file(path, string(document)) == nil) {return}
	controls, loaded := load(path)
	if !testing.expect(t, loaded) {return}
	defer destroy(&controls)
	controls.mappings.axes["wheel"] = {type="mouse_wheel",scale=math.nan_f32()}
	testing.expect(t, !save(&controls))
	data, err := os.read_entire_file(path, context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(data)
	testing.expect(t, string(data) == document, "a rejected save leaves the previous mapping document intact")
	testing.expect(t, !save(nil))
	controls.path = ""
	testing.expect(t, !save(&controls))
}

@(test)
load_rejects_non_string_schema :: proc(t: ^testing.T) {
	path := temporary_input_path(t)
	if path == "" {return}
	defer delete(path)
	defer os.remove(path)
	document :: `{"$schema":123,"actions":{},"axes":{}}`
	if !testing.expect(t, os.write_entire_file(path, string(document)) == nil) {return}
	controls, loaded := load(path)
	defer destroy(&controls)
	testing.expect(t, !loaded)
}
