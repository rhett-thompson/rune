package validation

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "rune:jsonutil"
import "rune:ecs"
import "rune:prefab"
import "rune:terrain"
import "rune:navigation"

// Diagnostic describes one authoring problem. `path` is a JSON-style field
// path, so the same report can later be shown by command-line tools or an
// editor inspector.
Diagnostic :: struct {
	file:    string,
	path:    string,
	message: string,
}

// Report owns its diagnostics and all JSON/path scratch storage. Call
// destroy_report when the caller has finished reading it.
Report :: struct {
	diagnostics: [dynamic]Diagnostic,
	arena:       ^mem.Dynamic_Arena,
}

is_valid :: proc(report: ^Report) -> bool {return len(report.diagnostics) == 0}

init_report :: proc() -> Report {
	arena, _ := mem.new(mem.Dynamic_Arena)
	assert(arena != nil)
	mem.dynamic_arena_init(arena)
	allocator := mem.dynamic_arena_allocator(arena)
	return Report{diagnostics = make([dynamic]Diagnostic, allocator), arena = arena}
}

destroy_report :: proc(report: ^Report) {
	if report == nil || report.arena == nil {return}
	mem.dynamic_arena_destroy(report.arena)
	mem.free(report.arena)
	report^ = {}
}

report_allocator :: proc(report: ^Report) -> mem.Allocator {
	return mem.dynamic_arena_allocator(report.arena)
}

field_path :: proc(path, name: string) -> string {return fmt.tprintf("%s.%s", path, name)}
index_path :: proc(path: string, index: int) -> string {return fmt.tprintf("%s[%d]", path, index)}
layer_path :: proc(name: string) -> string {return fmt.tprintf("$.layers.%s", name)}

add :: proc(report: ^Report, file, path, message: string) {
	allocator := report_allocator(report)
	owned_file, _ := strings.clone(file, allocator)
	owned_path, _ := strings.clone(path, allocator)
	owned_message, _ := strings.clone(message, allocator)
	append(
		&report.diagnostics,
		Diagnostic{file = owned_file, path = owned_path, message = owned_message},
	)
}

read_json_object :: proc(path: string, report: ^Report) -> (json.Object, bool) {
	allocator := report_allocator(report)
	data, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {
		add(report, path, "$", "file could not be read")
		return nil, false
	}
	value: json.Value
	if json.unmarshal(data, &value, allocator = allocator) != nil {
		add(report, path, "$", "invalid JSON")
		return nil, false
	}
	object, ok := value.(json.Object)
	if !ok {add(report, path, "$", "expected an object")}
	return object, ok
}

string_field :: proc(
	report: ^Report,
	file, path: string,
	object: json.Object,
	name: string,
	required: bool,
) -> (
	string,
	bool,
) {
	value, found := object[name]
	if !found {
		if required {add(report, file, field_path(path, name), "is required")}
		return "", !required
	}
	result, ok := value.(json.String)
	if !ok || len(result) == 0 {
		add(report, file, field_path(path, name), "must be a non-empty string")
		return "", false
	}
	return result, true
}

object_field :: proc(
	report: ^Report,
	file, path: string,
	object: json.Object,
	name: string,
	required: bool,
) -> (
	json.Object,
	bool,
) {
	value, found := object[name]
	if !found {
		if required {add(report, file, field_path(path, name), "is required")}
		return nil, !required
	}
	result, ok := value.(json.Object)
	if !ok {add(report, file, field_path(path, name), "must be an object")}
	return result, ok
}

array_field :: proc(
	report: ^Report,
	file, path: string,
	object: json.Object,
	name: string,
	required: bool,
) -> (
	json.Array,
	bool,
) {
	value, found := object[name]
	if !found {
		if required {add(report, file, field_path(path, name), "is required")}
		return nil, !required
	}
	result, ok := value.(json.Array)
	if !ok {add(report, file, field_path(path, name), "must be an array")}
	return result, ok
}

path_from :: proc(report: ^Report, directory, value: string) -> string {
	if filepath.is_abs(value) {return value}
	result, _ := filepath.join({directory, value}, report_allocator(report))
	return result
}

file_exists :: proc(path: string) -> bool {
	_, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil
}

// validate_project validates the project document and follows its startup
// scene, input document, and transitively referenced prefab files. Asset paths are
// resolved relative to the project file, matching the runtime asset manager.
validate_project :: proc(project_path: string) -> Report {
	report := init_report()
	project, ok := read_json_object(project_path, &report)
	if !ok {return report}
	project_directory, _ := filepath.split(project_path)
	string_field(&report, project_path, "$", project, "name", true)
	startup_scene, scene_ok := string_field(
		&report,
		project_path,
		"$",
		project,
		"startup_scene",
		false,
	)
	input_path, input_ok := string_field(&report, project_path, "$", project, "input", true)
	validate_window(&report, project_path, project)
	validate_render_2d(&report, project_path, project)
	layers := validate_layers(&report, project_path, project)
	if input_ok && len(input_path) > 0 {
		resolved_input := path_from(&report, project_directory, input_path)
		if !file_exists(
			resolved_input,
		) {add(&report, project_path, "$.input", fmt.tprint("referenced input file does not exist: ", resolved_input))}
	}
	if scene_ok && len(startup_scene) > 0 {
		validate_scene_at(
			&report,
			path_from(&report, project_directory, startup_scene),
			layers,
			project_directory,
		)
	}
	return report
}

validate_render_2d :: proc(report: ^Report, file: string, project: json.Object) {
	value, found := project["render_2d"]
	if !found {return}
	settings, ok := value.(json.Object)
	if !ok {add(report,file,"$.render_2d","must be an object"); return}
	policy: string = "native"
	if value, found := settings["policy"]; found {
		policy, ok = value.(json.String)
		if !ok || (policy!="native" && policy!="fit" && policy!="stretch" && policy!="integer") {
			add(report,file,"$.render_2d.policy","must be native, fit, stretch, or integer")
		}
	}
	for field in ([2]string{"width","height"}) {
		value, found := settings[field]
		if !found && policy=="native" {continue}
		number, ok := jsonutil.number(value)
		if !found || !ok || number<1 || number>8192 || number!=f32(i32(number)) {
			add(report,file,field_path("$.render_2d",field),"must be an integer from 1 to 8192")
		}
	}
}

validate_window :: proc(report: ^Report, file: string, project: json.Object) {
	window, found := project["window"]
	if !found {add(report, file, "$.window", "is required"); return}
	settings, ok := window.(json.Object)
	if !ok {add(report, file, "$.window", "must be an object"); return}
	dimension_fields := [2]string{"width", "height"}
	for field in dimension_fields {
		value, has_value := settings[field]
		if !has_value {continue}
		number, number_ok := jsonutil.number(value)
		if !number_ok || number != f32(i32(number)) || number <= 0 {
			add(report, file, field_path("$.window", field), "must be a positive integer")
		}
	}
	if value, has_title := settings["title"]; has_title {
		if _, title_ok := value.(json.String);
		   !title_ok {add(report, file, "$.window.title", "must be a string")}
	}
	for field in ([]string{"fullscreen", "high_dpi", "resizable", "vsync", "msaa_4x", "show_fps"}) {
		if value, found := settings[field]; found {
			if _, ok := value.(json.Boolean); !ok {add(report, file, field_path("$.window", field), "must be a boolean")}
		}
	}
	if value, found := settings["mode"]; found {
		mode, ok := value.(json.String)
		if !ok || (mode != "windowed" && mode != "borderless" && mode != "fullscreen") {
			add(report, file, "$.window.mode", "must be windowed, borderless, or fullscreen")
		}
	}
}

validate_layers :: proc(report: ^Report, file: string, project: json.Object) -> map[string]u8 {
	result := make(map[string]u8, report_allocator(report))
	value, found := project["layers"]
	if !found {return result}
	layers, ok := value.(json.Object)
	if !ok {add(report, file, "$.layers", "must be an object"); return result}
	for name, index_value in layers {
		index, number_ok := jsonutil.number(index_value)
		if name == "Default" || !number_ok || index != f32(u8(index)) || index < 1 || index >= 64 {
			add(
				report,
				file,
				layer_path(name),
				"must be a unique integer from 1 through 63; Default is reserved",
			)
			continue
		}
		for existing_name, existing_index in result {
			if existing_index ==
			   u8(
				   index,
			   ) {add(report, file, layer_path(name), fmt.tprint("reuses layer bit assigned to ", existing_name))}
		}
		result[name] = u8(index)
	}
	return result
}

validate_scene :: proc(scene_path: string) -> Report {
	return validate_scene_with_layers(scene_path, nil)
}

// validate_scene_with_layers additionally checks scene layer names against the
// project's declared layer table. Standalone tools can pass nil when only the
// built-in Default layer is available.
validate_scene_with_layers :: proc(scene_path: string, layers: map[string]u8) -> Report {
	report := init_report()
	validate_scene_at(&report, scene_path, layers, "")
	return report
}

validate_scene_at :: proc(
	report: ^Report,
	scene_path: string,
	layers: map[string]u8,
	project_directory: string,
) {
	scene, ok := read_json_object(scene_path, report)
	if !ok {return}
	string_field(report, scene_path, "$", scene, "name", true)
	resolved := prefab.resolve_scene(scene, scene_path, report_allocator(report))
	if resolved.error != "" {add(report, scene_path, "$", resolved.error); return}
	scene = resolved.value.(json.Object)
	entities, entities_ok := array_field(report, scene_path, "$", scene, "entities", true)
	if !entities_ok {return}
	scene_directory, _ := filepath.split(scene_path)
	ids := make(map[string]bool, report_allocator(report))
	for entity, index in entities {
		validate_entity(
			report,
			scene_path,
			index_path("$.entities", index),
			entity,
			scene_directory,
			project_directory,
			layers,
			&ids,
		)
	}
}

validate_entity :: proc(
	report: ^Report,
	file, path: string,
	value: json.Value,
	scene_directory, project_directory: string,
	layers: map[string]u8,
	ids: ^map[string]bool,
) {
	entity, ok := value.(json.Object)
	if !ok {add(report, file, path, "must be an object"); return}
	if id, id_ok := string_field(report, file, path, entity, "id", false); id_ok && len(id) > 0 {
		if ids^[id] {add(report, file, field_path(path, "id"), "duplicates another entity ID")}
		ids^[id] = true
	}
	validate_entity_layers(report, file, path, entity, layers)
	validate_enabled(report, file, path, entity)
	components, components_ok := object_field(report, file, path, entity, "components", false)
	if components_ok {validate_components(report, file, field_path(path, "components"), components, project_directory)}
	if prefab_path, prefab_ok := string_field(report, file, path, entity, "prefab", false);
	   prefab_ok && len(prefab_path) > 0 {
		resolved_prefab := path_from(report, scene_directory, prefab_path)
		validate_prefab(report, resolved_prefab, project_directory)
	}
	children, children_ok := array_field(report, file, path, entity, "children", false)
	if children_ok {
		for child, child_index in children {
			validate_entity(
				report,
				file,
				index_path(field_path(path, "children"), child_index),
				child,
				scene_directory,
				project_directory,
				layers,
				ids,
			)
		}
	}
}

validate_entity_layers :: proc(
	report: ^Report,
	file, path: string,
	entity: json.Object,
	layers: map[string]u8,
) {
	value, found := entity["layers"]
	if !found {return}
	values, ok := value.(json.Array)
	if !ok {add(report, file, field_path(path, "layers"), "must be an array of layer names"); return}
	for value, index in values {
		name, name_ok := value.(json.String)
		if !name_ok ||
		   len(name) ==
			   0 {add(report, file, index_path(field_path(path, "layers"), index), "must be a non-empty string"); continue}
		if name != "Default" && layers != nil {
			if _, found := layers[name];
			   !found {add(report, file, index_path(field_path(path, "layers"), index), "is not declared by project.json")}
		}
	}
}

// Validate the same expanded data used at runtime, including nested dependencies.
validate_prefab :: proc(report: ^Report, prefab_path, project_directory: string) {
	allocator := report_allocator(report)
	absolute, error := filepath.abs(prefab_path, allocator)
	if error != nil {add(report, prefab_path, "$", "could not resolve prefab path"); return}
	entity := make(json.Object, allocator)
	entity["id"] = "prefab"
	entity["prefab"] = absolute
	entities := make(json.Array, 0, 1, allocator)
	append(&entities, entity)
	document := make(json.Object, allocator)
	document["entities"] = entities
	result := prefab.resolve_scene(document, prefab_path, allocator)
	if result.error != "" {add(report, prefab_path, "$", result.error); return}
	resolved := result.value.(json.Object)["entities"].(json.Array)
	directory, _ := filepath.split(prefab_path)
	ids := make(map[string]bool, allocator)
	validate_entity(report, prefab_path, "$", resolved[0], directory, project_directory, nil, &ids)
}

validate_components :: proc(
	report: ^Report,
	file, path: string,
	components: json.Object,
	project_directory: string,
) {
	for name, value in components {
		component, ok := value.(json.Object)
		if !ok {add(report, file, field_path(path, name), "component data must be an object"); continue}
		if name == "PostProcessing" {
			if _, valid := ecs.post_processing_from_json(value); !valid {
				add(report, file, field_path(path, name), "invalid post-processing profile: check effect fields, lowercase modes, finite ranges, fog end > start, and max_ev >= min_ev (see docs/post-processing.md)")
			}
		}
		if name == "Interactable3D" || name == "Interactor3D" {
			valid:bool
			if name=="Interactable3D" {_,valid=ecs.interaction_component_3d_from_json(value,ecs.Interactable3D)}
			else {_,valid=ecs.interaction_component_3d_from_json(value,ecs.Interactor3D)}
			if !valid {add(report,file,field_path(path,name),"invalid interaction settings: use a nonempty prompt, finite offset, nonnegative hold time, positive range, and half-angle from 0 to 180")}
			if _,exists:=components["Transform"]; !exists {add(report,file,field_path(path,name),"3D interaction components require Transform")}
		}
		if name == "NavMesh3D" {
			config,valid:=ecs.nav_component_3d_from_json(value,ecs.NavMesh3D)
			if !valid {add(report,file,field_path(path,name),"NavMesh3D requires an asset path")}
			else if project_directory!="" {
				mesh,error:=navigation.load_mesh_3d(path_from(report,project_directory,config.asset))
				if error!="" {add(report,file,field_path(field_path(path,name),"asset"),error)} else {navigation.destroy_mesh_3d(&mesh)}
			}
		}
		if name == "NavAgent3D" {
			if _,valid:=ecs.nav_component_3d_from_json(value,ecs.NavAgent3D); !valid {add(report,file,field_path(path,name),"NavAgent3D requires a mesh entity reference, finite nonnegative settings, positive height/arrival/repath values, and slope below 89 degrees")}
			if _,exists:=components["Transform"]; !exists {add(report,file,field_path(path,name),"NavAgent3D requires an unparented unit-scale Transform")}
		}
		if name == "Skybox" {
			sky, valid := ecs.skybox_from_json(value)
			if !valid {
				add(report, file, field_path(path, name), "invalid skybox: check mode/layout, finite ranges, nonzero procedural sun direction, atmosphere.sun entity ID for atmospheric mode, and power-of-two resolution from 16 to 2048 (see docs/skybox.md)")
			} else if sky.mode == .cubemap {
				asset_path := field_path(field_path(path, name), "texture")
				if !supported_texture_path(sky.texture) && strings.to_lower(filepath.ext(sky.texture), context.temp_allocator) != ".hdr" {
					add(report, file, asset_path, "unsupported skybox image format; use .hdr, .png, .bmp, .gif, .qoi, or .dds")
				}
				if len(project_directory) > 0 && !file_exists(path_from(report, project_directory, sky.texture)) {
					add(report, file, asset_path, fmt.tprint("referenced skybox does not exist: ", sky.texture))
				}
			}
		}
		if name == "Terrain" {
			settings,valid := ecs.terrain_from_json(value)
			if !valid {add(report,file,field_path(path,name),"requires asset path, boolean collision/shadows and finite nonnegative friction")}
			for other in ([]string{"RigidBody3D","BoxCollider","SphereCollider","CharacterController","CharacterController3D"}) {
				if _,exists := components[other]; exists {add(report,file,field_path(path,name),fmt.tprint("Terrain cannot share an entity with ",other))}
			}
			if _,exists := components["Transform"]; !exists {add(report,file,field_path(path,name),"Terrain requires Transform")}
			if valid && project_directory != "" {
				data,watch,error := terrain.load(project_directory,settings.asset)
				if error != "" {add(report,file,field_path(path,name),fmt.tprintf("%s (%s): %s",settings.asset,watch,error))} else {
					if data.description.material != "" {validate_material(report,path_from(report,project_directory,data.description.material),project_directory)}
					terrain.destroy(&data)
				}
			}
		}
		if name == "PolygonCollider2D" {
			if _, valid := ecs.polygon_collider_2d_from_json(value); !valid {
				add(report, file, field_path(path, name), "requires 3-8 finite convex perimeter vertices, no duplicate/collinear/short edges, and finite 2D offset")
			}
		}
		if name == "SegmentCollider2D" {
			if _, valid := ecs.segment_collider_2d_from_json(value); !valid {
				add(report, file, field_path(path, name), "requires finite 2D start/end points more than 0.005 units apart and finite offset; one_way requires a horizontal, non-sensor edge")
			}
		}
		if name == "CharacterController3D" {
			if _, valid := ecs.character_controller_3d_from_json(value); !valid {
				add(report,file,field_path(path,name),"requires finite nonnegative settings, positive radius/acceleration/braking/gravity/fall speed, 2*radius <= crouch_height <= height, step_height < height, sprint_multiplier >= 1, slope < 89, and jump cut/grace/buffer values in [0,1]")
			}
		}
		if name == "CharacterController2D" {
			if _, valid := ecs.character_controller_2d_from_json(value); !valid {
				add(report,file,field_path(path,name),"requires finite nonnegative settings, positive acceleration/gravity/fall/drop speed, slope angle < 89 degrees, grace/drop/wall-lock times <= 1 second, jump_cut_multiplier between 0 and 1, dash_duration in (0,1], dash_chain_window in [0,1], integer dash_chain_count in [1,32], and boolean dash_on_ground/dash_in_air")
			}
		}
		if name == "CapsuleCollider2D" {
			if _, valid := ecs.capsule_collider_2d_from_json(value); !valid {
				add(report, file, field_path(path, name), "requires positive radius, height >= 2 * radius, vertical/horizontal axis, and finite 2D offset")
			}
		}
		if name == "BoxCollider2D" {
			if _, valid := ecs.box_collider_2d_from_json(value); !valid {
				add(report, file, field_path(path, name), "requires positive size, finite 2D offset, boolean is_sensor/one_way, and no sensor + one_way combination")
			}
		}
		if name == "CircleCollider2D" {
			if _, valid := ecs.circle_collider_2d_from_json(value); !valid {
				add(report, file, field_path(path, name), "requires positive radius, finite 2D offset, and boolean is_sensor")
			}
		}
		if name == "ShapeRenderer2D" {
			if _, valid := ecs.shape_renderer_2d_from_json(value); !valid {
				add(report, file, field_path(path, name), "invalid shape settings: use rectangle/circle, positive dimensions and line_width, and RGBA color")
			}
		}
		if name == "Lifetime" {
			if _, valid := ecs.lifetime_from_json(value); !valid {
				add(report, file, field_path(path, name), "must contain only seconds, a finite nonnegative number")
			}
		}
		if name == "AudioPlayer" {
			if len(component) ==
			   0 {add(report, file, field_path(path, name), "must define at least one named instance"); continue}
			for instance_name, instance_value in component {
				instance, instance_ok := instance_value.(json.Object)
				instance_path := field_path(field_path(path, name), instance_name)
				if len(instance_name) == 0 || !instance_ok {
					add(report, file, instance_path, "named component instance must be an object")
					continue
				}
				player, valid := ecs.audio_player_from_json(instance_value)
				if !valid {add(report, file, instance_path, "requires sound or a non-empty clips list and valid audio settings"); continue}
				for clip, i in player.clips {
					if len(project_directory) > 0 && !file_exists(path_from(report, project_directory, clip)) {
						add(report, file, fmt.tprint(instance_path, ".clips[", i, "]"), fmt.tprint("referenced asset does not exist: ", clip))
					}
				}
				validate_component_assets(report, file, instance_path, instance, project_directory)
			}
			continue
		}
		validate_component_assets(
			report,
			file,
			field_path(path, name),
			component,
			project_directory,
			allow_empty_texture = name == "ParticleEmitter2D",
		)
		if name == "ModelRenderer" {
			validate_material_overrides(
				report,
				file,
				field_path(path, name),
				component,
				project_directory,
			)
		}
		if name == "SpriteAnimator" {
			validate_sprite_animator_clip(
				report,
				file,
				field_path(path, name),
				component,
				project_directory,
			)
		}
	}
}

validate_component_assets :: proc(
	report: ^Report,
	file, path: string,
	component: json.Object,
	project_directory: string,
	allow_empty_texture: bool = false,
) {
	asset_fields := [6]string{"texture", "model", "font", "sound", "animation", "tileset"}
	for field in asset_fields {
		asset_path, found := component[field]
		if !found {continue}
		asset, ok := asset_path.(json.String)
		if allow_empty_texture && field == "texture" && ok && asset == "" {continue}
		if field == "sound" && ok && asset == "" {if clips, valid := component["clips"].(json.Array); valid && len(clips) > 0 {continue}}
		if !ok ||
		   len(asset) ==
			   0 {add(report, file, field_path(path, field), "must be a non-empty asset path"); continue}
		if field == "texture" {
			validate_texture_reference(
				report,
				file,
				field_path(path, field),
				asset,
				project_directory,
			)
			continue
		}
		if field == "animation" {
			validate_animation_reference(
				report,
				file,
				field_path(path, field),
				asset_path,
				project_directory,
			)
			continue
		}
		if field == "tileset" {
			validate_tileset_reference(
				report,
				file,
				field_path(path, field),
				asset_path,
				project_directory,
			)
			continue
		}
		if len(project_directory) > 0 &&
		   !file_exists(path_from(report, project_directory, asset)) {
			add(
				report,
				file,
				field_path(path, field),
				fmt.tprint("referenced asset does not exist: ", asset),
			)
		}
	}
	if material_path, found := component["material"]; found {
		validate_material_reference(
			report,
			file,
			field_path(path, "material"),
			material_path,
			project_directory,
		)
	}
}

validate_material :: proc(report: ^Report, material_path, project_directory: string) {
	material, ok := read_json_object(material_path, report)
	if !ok {return}
	if color_value, found := material["base_color"]; found {
		color, color_ok := color_value.(json.Array)
		if !color_ok || len(color) != 4 {
			add(
				report,
				material_path,
				"$.base_color",
				"must be an RGBA array with four integer channels",
			)
		} else {
			for channel, index in color {
				number, number_ok := jsonutil.number(channel)
				if !number_ok || number < 0 || number > 255 || number != f32(i32(number)) {
					add(
						report,
						material_path,
						index_path("$.base_color", index),
						"must be an integer from 0 through 255",
					)
				}
			}
		}
	}
	if color_value, found := material["emission_color"]; found {
		color, color_ok := color_value.(json.Array)
		if !color_ok || len(color) != 4 {
			add(
				report,
				material_path,
				"$.emission_color",
				"must be an RGBA array with four integer channels",
			)
		} else {
			for channel, index in color {
				number, number_ok := jsonutil.number(channel)
				if !number_ok || number < 0 || number > 255 || number != f32(i32(number)) {
					add(
						report,
						material_path,
						index_path("$.emission_color", index),
						"must be an integer from 0 through 255",
					)
				}
			}
		}
	}
	material_asset_fields := [13]string {
		"texture",
		"albedo",
		"normal",
		"emission",
		"emission_texture",
		"orm_texture",
		"orm",
		"roughness_texture",
		"metallic_texture",
		"ao_texture",
		"occlusion",
		"height_texture",
		"height",
	}
	for field in material_asset_fields {
		asset_path, found := material[field]
		if !found {continue}
		asset, asset_ok := asset_path.(json.String)
		if !asset_ok || len(asset) == 0 {
			add(report, material_path, field_path("$", field), "must be a non-empty asset path")
			continue
		}
		validate_texture_reference(
			report,
			material_path,
			field_path("$", field),
			asset,
			project_directory,
		)
	}
	if lighting_value, found := material["lighting"]; found {
		if _, ok := lighting_value.(json.Boolean); !ok {
			add(report, material_path, "$.lighting", "must be a boolean")
		}
	}
	if mipmaps_value, found := material["mipmaps"]; found {
		if _, ok := mipmaps_value.(json.Boolean); !ok {
			add(report, material_path, "$.mipmaps", "must be a boolean")
		}
	}
	if filter_value, found := material["filter"]; found {
		filter, filter_ok := filter_value.(json.String)
		if !filter_ok || !valid_texture_filter(filter) {
			add(
				report,
				material_path,
				"$.filter",
				"must be one of point, bilinear, trilinear, anisotropic_4x, anisotropic_8x, anisotropic_16x",
			)
		}
	}
	if lod_bias_value, found := material["lod_bias"]; found {
		lod_bias, lod_bias_ok := jsonutil.number(lod_bias_value)
		if !lod_bias_ok || lod_bias < 0 || lod_bias > 4 {
			add(report, material_path, "$.lod_bias", "must be a number from 0 through 4")
		}
	}
	material_unit_fields := [6]string {
		"roughness",
		"metallic",
		"specular",
		"ao_strength",
		"alpha_cutoff",
		"normal_scale",
	}
	for field in material_unit_fields {
		value, found := material[field]
		if !found {continue}
		number, number_ok := jsonutil.number(value)
		max_value: f32 = 1
		if field == "normal_scale" {max_value = 4}
		if !number_ok || number < 0 || number > max_value {
			add(
				report,
				material_path,
				field_path("$", field),
				fmt.tprint("must be a number from 0 through ", max_value),
			)
		}
	}
	if emission_energy_value, found := material["emission_energy"]; found {
		emission_energy, emission_energy_ok := jsonutil.number(emission_energy_value)
		if !emission_energy_ok || emission_energy < 0 {
			add(
				report,
				material_path,
				"$.emission_energy",
				"must be a number greater than or equal to 0",
			)
		}
	}
	if transparency_value, found := material["transparency"]; found {
		transparency, transparency_ok := transparency_value.(json.String)
		if !transparency_ok || !valid_transparency_mode(transparency) {
			add(report, material_path, "$.transparency", "must be one of disabled, prepass, alpha")
		}
	}
	if blend_value, found := material["blend"]; found {
		blend, blend_ok := blend_value.(json.String)
		if !blend_ok || !valid_blend_mode(blend) {
			add(
				report,
				material_path,
				"$.blend",
				"must be one of mix, additive, multiply, premultiplied_alpha",
			)
		}
	}
	if cull_value, found := material["cull"]; found {
		cull, cull_ok := cull_value.(json.String)
		if !cull_ok || !valid_cull_mode(cull) {
			add(report, material_path, "$.cull", "must be one of back, front, none")
		}
	}
	if height_scale_value, found := material["height_scale"]; found {
		height_scale, height_scale_ok := jsonutil.number(height_scale_value)
		if !height_scale_ok || height_scale < 0 || height_scale > 0.2 {
			add(report, material_path, "$.height_scale", "must be a number from 0 through 0.2")
		}
	}
}

valid_texture_filter :: proc(name: string) -> bool {
	return(
		name == "point" ||
		name == "bilinear" ||
		name == "trilinear" ||
		name == "anisotropic_4x" ||
		name == "anisotropic_8x" ||
		name == "anisotropic_16x" \
	)
}

valid_transparency_mode :: proc(name: string) -> bool {
	return name == "disabled" || name == "prepass" || name == "alpha"
}

valid_blend_mode :: proc(name: string) -> bool {
	return(
		name == "mix" ||
		name == "additive" ||
		name == "multiply" ||
		name == "premultiplied_alpha" \
	)
}

valid_cull_mode :: proc(name: string) -> bool {
	return name == "back" || name == "front" || name == "none"
}

validate_enabled :: proc(report: ^Report, file, path: string, entity: json.Object) {
	if value, found := entity["enabled"]; found {
		if _, valid := value.(json.Boolean); !valid {add(report, file, field_path(path, "enabled"), "must be a boolean")}
	}
}
