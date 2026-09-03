package assets

import "core:encoding/json"
import "core:os"
import "core:strings"
import "rune:jsonutil"

Animation_Clip :: struct {
	frames: []i32,
	origin: [2]i32,
	fps:    f32,
	loop:   bool,
}

Animation_Data :: struct {
	texture:    string,
	frame_size: [2]i32,
	clips:      map[string]Animation_Clip,
}

Animation_Asset :: struct {
	data:          Animation_Data,
	modified_time: i64,
	revision:      u64,
}

// animation returns cached, read-only animation data and its hot-reload
// revision. The texture path is project-relative, just like renderer assets.
animation :: proc(manager: ^Asset_Manager, path: string) -> (Animation_Data, u64, bool) {
	if manager == nil || len(path) == 0 {return {}, 0, false}
	if asset, found := manager.animations[path]; found {
		return asset.data, asset.revision, true
	}
	full_path := resolve_path(manager, path)
	data, loaded := load_animation_data(full_path)
	if !loaded {
		report_failure(
			manager,
			Diagnostic {
				kind = .Animation,
				operation = .Load,
				source_path = path,
				field = "$",
				asset_path = path,
				detail = "could not read or parse animation JSON",
			},
		)
		return {}, 0, false
	}
	resolve_asset_failure(manager, path, "$", path)
	manager.animations[retain_path(manager, path)] = Animation_Asset {
		data          = data,
		modified_time = modified_time(full_path),
		revision      = 1,
	}
	return data, 1, true
}

// load_animation_data is also useful to headless validators that do not create
// a raylib window. The caller owns the returned value.
load_animation_data :: proc(full_path: string) -> (Animation_Data, bool) {
	file_data, read_error := os.read_entire_file(full_path, context.allocator)
	if read_error != nil {return {}, false}
	defer delete(file_data)
	value: json.Value
	if json.unmarshal(file_data, &value) != nil {return {}, false}
	defer json.destroy_value(value)
	object, ok := value.(json.Object)
	if !ok {return {}, false}

	texture_value, has_texture := object["texture"]
	frame_size_value, has_frame_size := object["frame_size"]
	clips_value, has_clips := object["clips"]
	if !has_texture || !has_frame_size || !has_clips {return {}, false}
	texture, texture_ok := texture_value.(json.String)
	if !texture_ok || len(texture) == 0 {return {}, false}
	frame_size_array, frame_size_ok := frame_size_value.(json.Array)
	if !frame_size_ok || len(frame_size_array) != 2 {return {}, false}
	frame_size: [2]i32
	for number_value, index in frame_size_array {
		number, number_ok := jsonutil.number(number_value)
		if !number_ok || number <= 0 || number != f32(i32(number)) {return {}, false}
		frame_size[index] = i32(number)
	}
	clips_object, clips_ok := clips_value.(json.Object)
	if !clips_ok || len(clips_object) == 0 {return {}, false}

	result := Animation_Data {
		texture    = clone_asset_string(texture),
		frame_size = frame_size,
		clips      = make(map[string]Animation_Clip),
	}
	valid := false
	defer if !valid {destroy_animation_data(&result)}
	for name, clip_value in clips_object {
		if len(name) == 0 {return {}, false}
		clip_object, clip_ok := clip_value.(json.Object)
		if !clip_ok {return {}, false}
		frames_value, has_frames := clip_object["frames"]
		if !has_frames {return {}, false}
		frames_array, frames_ok := frames_value.(json.Array)
		if !frames_ok || len(frames_array) == 0 {return {}, false}
		clip := Animation_Clip {
			frames = make([]i32, len(frames_array)),
			fps    = 12,
			loop   = true,
		}
		clip_valid := false
		defer if !clip_valid {delete(clip.frames)}
		for frame_value, index in frames_array {
			frame, frame_ok := jsonutil.number(frame_value)
			if !frame_ok || frame < 0 || frame != f32(i32(frame)) {return {}, false}
			clip.frames[index] = i32(frame)
		}
		if origin_value, found := clip_object["origin"]; found {
			origin, origin_ok := origin_value.(json.Array)
			if !origin_ok || len(origin) != 2 {return {}, false}
			for coordinate_value, index in origin {
				coordinate, coordinate_ok := jsonutil.number(coordinate_value)
				if !coordinate_ok || coordinate < 0 || coordinate != f32(i32(coordinate)) {
					return {}, false
				}
				clip.origin[index] = i32(coordinate)
			}
		}
		if fps_value, found := clip_object["fps"]; found {
			clip.fps, clip_ok = jsonutil.number(fps_value)
			if !clip_ok || clip.fps <= 0 {return {}, false}
		}
		if loop_value, found := clip_object["loop"]; found {
			clip.loop, clip_ok = loop_value.(json.Boolean)
			if !clip_ok {return {}, false}
		}
		owned_name, _ := strings.clone(name)
		result.clips[owned_name] = clip
		clip_valid = true
	}
	valid = true
	return result, true
}

refresh_animations :: proc(manager: ^Asset_Manager) {
	if manager == nil {return}
	for path, asset in manager.animations {
		full_path := resolve_path(manager, path)
		current_time := modified_time(full_path)
		if current_time == asset.modified_time {continue}
		data, loaded := load_animation_data(full_path)
		if !loaded {
			report_failure(
				manager,
				Diagnostic {
					kind = .Animation,
					operation = .Reload,
					source_path = path,
					field = "$",
					asset_path = path,
					detail = "invalid animation JSON; keeping the previous animation",
				},
			)
			continue
		}
		resolve_asset_failure(manager, path, "$", path)
		previous_data := asset.data
		updated_asset := asset
		updated_asset.data = data
		updated_asset.modified_time = current_time
		updated_asset.revision += 1
		if updated_asset.revision == 0 {updated_asset.revision = 1}
		manager.animations[path] = updated_asset
		destroy_animation_data(&previous_data)
	}
}

destroy_animation_data :: proc(data: ^Animation_Data) {
	if data == nil {return}
	delete(data.texture)
	for name, clip in data.clips {
		delete(clip.frames)
		delete(name)
	}
	delete(data.clips)
	data^ = {}
}
