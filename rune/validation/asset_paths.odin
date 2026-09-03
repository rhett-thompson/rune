package validation

import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "rune:jsonutil"

SUPPORTED_TEXTURE_FORMATS :: ".png, .bmp, .gif, .qoi, and .dds"

supported_texture_path :: proc(path: string) -> bool {
	extension := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return(
		extension == ".png" ||
		extension == ".bmp" ||
		extension == ".gif" ||
		extension == ".qoi" ||
		extension == ".dds" \
	)
}

validate_texture_reference :: proc(report: ^Report, file, path, asset, project_directory: string) {
	if !supported_texture_path(asset) {
		extension := filepath.ext(asset)
		if len(extension) == 0 {extension = "<none>"}
		add(
			report,
			file,
			path,
			fmt.tprintf(
				"unsupported texture format %s; supported formats are %s",
				extension,
				SUPPORTED_TEXTURE_FORMATS,
			),
		)
	}
	if len(project_directory) > 0 && !file_exists(path_from(report, project_directory, asset)) {
		add(report, file, path, fmt.tprint("referenced asset does not exist: ", asset))
	}
}

validate_material_reference :: proc(
	report: ^Report,
	file, path: string,
	value: json.Value,
	project_directory: string,
) {
	material, ok := value.(json.String)
	if !ok || len(material) == 0 {
		add(report, file, path, "must be a non-empty material path")
		return
	}
	if len(project_directory) == 0 {return}
	resolved := path_from(report, project_directory, material)
	if !file_exists(resolved) {
		add(report, file, path, fmt.tprint("referenced material does not exist: ", material))
		return
	}
	validate_material(report, resolved, project_directory)
}

validate_material_overrides :: proc(
	report: ^Report,
	file, path: string,
	component: json.Object,
	project_directory: string,
) {
	value, found := component["materials"]
	if !found {return}
	overrides, ok := value.(json.Object)
	if !ok {
		add(
			report,
			file,
			field_path(path, "materials"),
			"must be an object keyed by material slot",
		)
		return
	}
	for slot_name, material_value in overrides {
		slot_path := field_path(field_path(path, "materials"), slot_name)
		slot, slot_ok := strconv.parse_int(slot_name, 10)
		if !slot_ok || slot < 0 || slot > 2147483647 {
			add(
				report,
				file,
				slot_path,
				"material slot must be an integer from 0 through 2147483647",
			)
			continue
		}
		validate_material_reference(report, file, slot_path, material_value, project_directory)
	}
}

validate_tileset_reference :: proc(
	report: ^Report,
	file, path: string,
	value: json.Value,
	project_directory: string,
) {
	tileset, ok := value.(json.String)
	if !ok || len(tileset) == 0 {
		add(report, file, path, "must be a non-empty tileset path")
		return
	}
	if len(project_directory) == 0 {return}
	resolved := path_from(report, project_directory, tileset)
	if !file_exists(resolved) {
		add(report, file, path, fmt.tprint("referenced tileset does not exist: ", tileset))
		return
	}
	validate_tileset(report, resolved, project_directory)
}

validate_tileset :: proc(report: ^Report, tileset_path, project_directory: string) {
	tileset, ok := read_json_object(tileset_path, report)
	if !ok {return}
	texture_value, has_texture := tileset["texture"]
	if !has_texture {
		add(report, tileset_path, "$.texture", "is required")
	} else if texture, texture_ok := texture_value.(json.String);
	   !texture_ok || len(texture) == 0 {
		add(report, tileset_path, "$.texture", "must be a non-empty texture path")
	} else {
		validate_texture_reference(report, tileset_path, "$.texture", texture, project_directory)
	}
	validate_tileset_vector(report, tileset_path, "$.tile_size", tileset["tile_size"], false)
	tiles_value, has_tiles := tileset["tiles"]
	if !has_tiles {
		add(report, tileset_path, "$.tiles", "is required")
		return
	}
	tiles, tiles_ok := tiles_value.(json.Object)
	if !tiles_ok || len(tiles) == 0 {
		add(report, tileset_path, "$.tiles", "must define at least one tile")
		return
	}
	for key, tile_value in tiles {
		tile_path := field_path("$.tiles", key)
		index, index_ok := strconv.parse_int(key, 10)
		if !index_ok || index < 0 || index > 2147483647 {
			add(report, tileset_path, tile_path, "tile ID must be a non-negative integer")
		}
		tile, tile_ok := tile_value.(json.Object)
		if !tile_ok {
			add(report, tileset_path, tile_path, "tile definition must be an object")
			continue
		}
		source, has_source := tile["source"]
		if !has_source {
			add(report, tileset_path, field_path(tile_path, "source"), "is required")
		} else {
			validate_tileset_vector(
				report,
				tileset_path,
				field_path(tile_path, "source"),
				source,
				true,
			)
		}
		if size, found := tile["size"]; found {
			validate_tileset_vector(
				report,
				tileset_path,
				field_path(tile_path, "size"),
				size,
				false,
			)
		}
		if name, found := tile["name"]; found {
			if text, name_ok := name.(json.String); !name_ok || len(text) == 0 {
				add(report, tileset_path, field_path(tile_path, "name"), "must be non-empty")
			}
		}
	}
}

validate_tileset_vector :: proc(
	report: ^Report,
	file, path: string,
	value: json.Value,
	allow_zero: bool,
) {
	array, ok := value.(json.Array)
	if !ok || len(array) != 2 {
		add(report, file, path, "must contain two integers")
		return
	}
	for coordinate_value, index in array {
		coordinate, coordinate_ok := jsonutil.number(coordinate_value)
		minimum: f32 = 1
		if allow_zero {minimum = 0}
		if !coordinate_ok || coordinate < minimum || coordinate != f32(i32(coordinate)) {
			message := "must be a positive integer"
			if allow_zero {message = "must be a non-negative integer"}
			add(report, file, index_path(path, index), message)
		}
	}
}

validate_animation_reference :: proc(
	report: ^Report,
	file, path: string,
	value: json.Value,
	project_directory: string,
) {
	animation, ok := value.(json.String)
	if !ok || len(animation) == 0 {
		add(report, file, path, "must be a non-empty animation path")
		return
	}
	if len(project_directory) == 0 {return}
	resolved := path_from(report, project_directory, animation)
	if !file_exists(resolved) {
		add(report, file, path, fmt.tprint("referenced animation does not exist: ", animation))
		return
	}
	validate_animation(report, resolved, project_directory)
}

validate_animation :: proc(report: ^Report, animation_path, project_directory: string) {
	animation, ok := read_json_object(animation_path, report)
	if !ok {return}
	texture_value, has_texture := animation["texture"]
	if !has_texture {
		add(report, animation_path, "$.texture", "is required")
	} else if texture, texture_ok := texture_value.(json.String);
	   !texture_ok || len(texture) == 0 {
		add(report, animation_path, "$.texture", "must be a non-empty texture path")
	} else {
		validate_texture_reference(report, animation_path, "$.texture", texture, project_directory)
	}

	frame_size_value, has_frame_size := animation["frame_size"]
	if !has_frame_size {
		add(report, animation_path, "$.frame_size", "is required")
	} else if frame_size, size_ok := frame_size_value.(json.Array);
	   !size_ok || len(frame_size) != 2 {
		add(report, animation_path, "$.frame_size", "must contain two positive integers")
	} else {
		for value, index in frame_size {
			number, number_ok := jsonutil.number(value)
			if !number_ok || number <= 0 || number != f32(i32(number)) {
				add(
					report,
					animation_path,
					index_path("$.frame_size", index),
					"must be a positive integer",
				)
			}
		}
	}

	clips_value, has_clips := animation["clips"]
	if !has_clips {
		add(report, animation_path, "$.clips", "is required")
		return
	}
	clips, clips_ok := clips_value.(json.Object)
	if !clips_ok || len(clips) == 0 {
		add(report, animation_path, "$.clips", "must define at least one named clip")
		return
	}
	for name, clip_value in clips {
		clip_path := field_path("$.clips", name)
		clip, clip_ok := clip_value.(json.Object)
		if len(name) == 0 || !clip_ok {
			add(report, animation_path, clip_path, "named clip must be an object")
			continue
		}
		frames_value, has_frames := clip["frames"]
		frames, frames_ok := frames_value.(json.Array)
		if !has_frames || !frames_ok || len(frames) == 0 {
			add(
				report,
				animation_path,
				field_path(clip_path, "frames"),
				"must contain frame indices",
			)
		} else {
			for value, index in frames {
				frame, frame_ok := jsonutil.number(value)
				if !frame_ok || frame < 0 || frame != f32(i32(frame)) {
					add(
						report,
						animation_path,
						index_path(field_path(clip_path, "frames"), index),
						"must be a non-negative integer",
					)
				}
			}
		}
		if fps_value, found := clip["fps"]; found {
			fps, fps_ok := jsonutil.number(fps_value)
			if !fps_ok || fps <= 0 {
				add(report, animation_path, field_path(clip_path, "fps"), "must be positive")
			}
		}
		if origin_value, found := clip["origin"]; found {
			origin, origin_ok := origin_value.(json.Array)
			origin_path := field_path(clip_path, "origin")
			if !origin_ok || len(origin) != 2 {
				add(report, animation_path, origin_path, "must contain two non-negative integers")
			} else {
				for value, index in origin {
					coordinate, coordinate_ok := jsonutil.number(value)
					if !coordinate_ok || coordinate < 0 || coordinate != f32(i32(coordinate)) {
						add(
							report,
							animation_path,
							index_path(origin_path, index),
							"must be a non-negative integer",
						)
					}
				}
			}
		}
		if loop_value, found := clip["loop"]; found {
			if _, loop_ok := loop_value.(json.Boolean); !loop_ok {
				add(report, animation_path, field_path(clip_path, "loop"), "must be a boolean")
			}
		}
	}
}

validate_sprite_animator_clip :: proc(
	report: ^Report,
	file, path: string,
	component: json.Object,
	project_directory: string,
) {
	clip_value, has_clip := component["clip"]
	clip, clip_ok := clip_value.(json.String)
	if !has_clip || !clip_ok || len(clip) == 0 {
		add(report, file, field_path(path, "clip"), "must be a non-empty clip name")
		return
	}
	animation_value, has_animation := component["animation"]
	animation, animation_ok := animation_value.(json.String)
	if !has_animation || !animation_ok || len(animation) == 0 || len(project_directory) == 0 {
		return
	}
	resolved := path_from(report, project_directory, animation)
	if !file_exists(resolved) {return}
	data, read_ok := read_json_object(resolved, report)
	if !read_ok {return}
	clips_value, has_clips := data["clips"]
	clips, clips_ok := clips_value.(json.Object)
	if !has_clips || !clips_ok {return}
	if _, found := clips[clip]; !found {
		add(
			report,
			file,
			field_path(path, "clip"),
			fmt.tprint("clip is not defined by animation: ", clip),
		)
	}
}
