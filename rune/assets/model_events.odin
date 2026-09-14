package assets

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"

Model_Animation_Marker :: struct {
	time: f32,
	name: string,
}

Model_Events_Data :: struct { clips: map[string][]Model_Animation_Marker }
Model_Events_Asset :: struct {
	data: Model_Events_Data,
	modified_time: i64,
	revision: u64,
}

// Caller owns successful data; error text uses frame scratch storage.
load_model_events_data :: proc(path: string) -> (Model_Events_Data, string) {
	bytes, error := os.read_entire_file(path, context.allocator)
	if error != nil {return {}, "could not read marker file"}
	defer delete(bytes)
	// Odin's generic JSON object parser drops empty keys. Reject them before
	// decoding so a misspelled empty track cannot silently disappear.
	tokens := json.make_tokenizer(string(bytes))
	empty_key := false
	for {
		token, token_error := json.get_token(&tokens)
		if token.kind == .EOF {break}
		if token_error != .None {return {}, "invalid marker JSON"}
		if token.kind == .Colon && empty_key {return {}, fmt.tprintf("line %d: object keys must not be empty", token.line)}
		empty_key = token.kind == .String && token.text == `""`
	}
	value: json.Value
	if json.unmarshal(bytes, &value) != nil {return {}, "invalid marker JSON"}
	defer json.destroy_value(value)
	root, ok := value.(json.Object)
	if !ok {return {}, "$ must be an object"}
	for key in root {if key != "$schema" && key != "clips" {return {}, fmt.tprintf("$.%s is unknown", key)}}
	clips, clips_ok := root["clips"].(json.Object)
	if !clips_ok || len(clips) == 0 {return {}, "$.clips must contain at least one named marker track"}
	data := Model_Events_Data{clips = make(map[string][]Model_Animation_Marker)}
	valid := false
	defer if !valid {destroy_model_events_data(&data)}
	for name, track_value in clips {
		if name == "" {return {}, "$.clips names must not be empty"}
		track, track_ok := track_value.(json.Array)
		if !track_ok || len(track) > MAX_ANIMATION_MARKERS {return {}, fmt.tprintf("$.clips.%s must be an array of at most 4096 markers", name)}
		markers := make([]Model_Animation_Marker, len(track))
		data.clips[clone_asset_string(name)] = markers
		previous: f32 = -1
		for entry, i in track {
			object, object_ok := entry.(json.Object)
			if !object_ok {return {}, fmt.tprintf("$.clips.%s[%d] must be an object", name, i)}
			for key in object {if key != "time" && key != "name" {return {}, fmt.tprintf("$.clips.%s[%d].%s is unknown", name, i, key)}}
			time: f64
			#partial switch number in object["time"] {
			case json.Integer: time = f64(number)
			case json.Float: time = f64(number)
			case: return {}, fmt.tprintf("$.clips.%s[%d].time must be a number", name, i)
			}
			if math.is_nan(time) || math.is_inf(time) || time < 0 || math.is_inf(f32(time)) || f32(time) < previous {
				return {}, fmt.tprintf("$.clips.%s[%d].time must be finite, nonnegative, and in nondecreasing order", name, i)
			}
			marker_name, named := object["name"].(json.String)
			if !named || marker_name == "" {return {}, fmt.tprintf("$.clips.%s[%d].name must be nonempty", name, i)}
			markers[i] = {f32(time), clone_asset_string(marker_name)}
			previous = f32(time)
		}
	}
	valid = true
	return data, ""
}

destroy_model_events_data :: proc(data: ^Model_Events_Data) {
	for name, markers in data.clips {
		for marker in markers {delete(marker.name)}
		delete(markers)
		delete(name)
	}
	delete(data.clips)
	data^ = {}
}

model_events :: proc(manager: ^Asset_Manager, path: string) -> (Model_Events_Data, u64, bool) {
	if manager == nil || path == "" {return {}, 0, false}
	if cached, found := manager.model_events[path]; found {return cached.data, cached.revision, true}
	full_path := resolve_path(manager, path)
	data, error := load_model_events_data(full_path)
	if error != "" {
		report_failure(manager, {kind = .Animation, operation = .Load, source_path = path, field = "ModelAnimator.events", asset_path = path, detail = error})
		return {}, 0, false
	}
	if manager.model_events == nil {manager.model_events = make(map[string]Model_Events_Asset)}
	manager.model_events[retain_path(manager, path)] = {data, modified_time(full_path), 1}
	resolve_asset_failure(manager, path, "ModelAnimator.events", path)
	return data, 1, true
}

refresh_model_events :: proc(manager: ^Asset_Manager) {
	if manager == nil {return}
	for path, &cached in manager.model_events {
		full_path := resolve_path(manager, path)
		modified := modified_time(full_path)
		if modified == cached.modified_time {continue}
		data, error := load_model_events_data(full_path)
		if error != "" {
			report_failure(manager, {kind = .Animation, operation = .Reload, source_path = path, field = "ModelAnimator.events", asset_path = path, detail = fmt.tprintf("%s; keeping previous markers", error)})
			continue
		}
		destroy_model_events_data(&cached.data)
		cached.data = data
		cached.modified_time = modified
		cached.revision += 1
		resolve_asset_failure(manager, path, "ModelAnimator.events", path)
	}
}
