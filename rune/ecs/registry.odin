package ecs

import "core:encoding/json"
import "core:mem"
import "core:reflect"
import "core:strings"

Typed_Component_Create_Proc :: #type proc(
	data: json.Value,
	default_value: any,
	allocator: mem.Allocator,
) -> (
	any,
	bool,
)

Component_Descriptor :: struct {
	name:           string,
	description:    string,
	allow_multiple: bool,
	type_id:        typeid,
	default_value:  any,
	create_typed:   Typed_Component_Create_Proc,
}

Component_Registry :: struct {
	components:           map[string]Component_Descriptor,
	names_by_type:        map[typeid]string,
	typed_defaults_arena: ^mem.Dynamic_Arena,
}

init_registry :: proc() -> Component_Registry {
	typed_defaults_arena, _ := mem.new(mem.Dynamic_Arena)
	assert(typed_defaults_arena != nil)
	mem.dynamic_arena_init(typed_defaults_arena)
	return Component_Registry {
		components = make(map[string]Component_Descriptor),
		names_by_type = make(map[typeid]string),
		typed_defaults_arena = typed_defaults_arena,
	}
}

destroy_registry :: proc(registry: ^Component_Registry) {
	if registry == nil || registry.typed_defaults_arena == nil {return}
	delete(registry.components)
	delete(registry.names_by_type)
	registry.components = nil
	registry.names_by_type = nil
	mem.dynamic_arena_destroy(registry.typed_defaults_arena)
	mem.free(registry.typed_defaults_arena)
	registry.typed_defaults_arena = nil
}

register_builtin_components :: proc(registry: ^Component_Registry) -> bool {
	transform_registered := register_builtin_component(
		registry,
		"Transform",
		Transform,
		"Position, rotation, and scale for an entity",
	)
	sprite_registered := register_builtin_component(
		registry,
		"SpriteRenderer",
		SpriteRenderer,
		"2D texture renderer",
	)
	mesh_registered := register_builtin_component(
		registry,
		"MeshRenderer",
		MeshRenderer,
		"Primitive 3D mesh renderer",
	)
	sphere_registered := register_builtin_component(
		registry,
		"SphereRenderer",
		SphereRenderer,
		"Sphere 3D renderer",
	)
	model_registered := register_builtin_component(
		registry,
		"ModelRenderer",
		ModelRenderer,
		"Asset-backed 3D model renderer",
	)
	ambient_light_registered := register_builtin_component(
		registry,
		"AmbientLight",
		AmbientLight,
		"Scene ambient light color and intensity",
	)
	directional_light_registered := register_builtin_component(
		registry,
		"DirectionalLight",
		DirectionalLight,
		"Directional scene light for lit 3D materials",
	)
	point_light_registered := register_builtin_component(
		registry,
		"PointLight",
		PointLight,
		"Local point light for lit 3D materials",
	)
	spot_light_registered := register_builtin_component(
		registry,
		"SpotLight",
		SpotLight,
		"Cone-shaped local light for lit 3D materials",
	)
	tilemap_registered := register_builtin_component(
		registry,
		"TilemapRenderer",
		TilemapRenderer,
		"Texture-atlas 2D tile grid",
	)
	text_registered := register_builtin_component(
		registry,
		"TextRenderer",
		TextRenderer,
		"Scene-authored 2D text",
	)
	tilemap_collider_registered := register_builtin_component(
		registry,
		"TilemapCollider",
		TilemapCollider,
		"Solid-tile collision for a TilemapRenderer",
	)
	top_down_controller_registered := register_builtin_component(
		registry,
		"TopDownController",
		TopDownController,
		"2D tilemap collision controller",
	)
	rigid_body_2d_registered := register_builtin_component(
		registry,
		"RigidBody2D",
		RigidBody2D,
		"Fixed-step 2D physics body",
	)
	box_collider_2d_registered := register_builtin_component(
		registry,
		"BoxCollider2D",
		BoxCollider2D,
		"2D axis-aligned box collider",
	)
	circle_collider_2d_registered := register_builtin_component(
		registry,
		"CircleCollider2D",
		CircleCollider2D,
		"2D circle collider",
	)
	rigid_body_3d_registered := register_builtin_component(
		registry,
		"RigidBody3D",
		RigidBody3D,
		"Box3D-backed 3D rigid body",
	)
	box_collider_registered := register_builtin_component(
		registry,
		"BoxCollider",
		BoxCollider,
		"Axis-aligned static collision volume",
	)
	sphere_collider_registered := register_builtin_component(
		registry,
		"SphereCollider",
		SphereCollider,
		"Sphere-shaped static collision volume",
	)
	character_controller_registered := register_builtin_component(
		registry,
		"CharacterController",
		CharacterController,
		"Gravity and collision player controller",
	)
	orbit_registered := register_builtin_component(
		registry,
		"Orbit",
		Orbit,
		"Moves an entity around its parent on the XZ plane",
	)
	rotator_registered := register_builtin_component(
		registry,
		"Rotator",
		Rotator,
		"Spins an entity around its local Y axis",
	)
	camera_2d_registered := register_builtin_component(
		registry,
		"Camera2D",
		Camera2D,
		"2D view controlled by an entity Transform",
	)
	camera_3d_registered := register_builtin_component(
		registry,
		"Camera3D",
		Camera3D,
		"3D view controlled by an entity Transform",
	)
	orbit_camera_3d_registered := register_builtin_component(
		registry,
		"OrbitCamera3D",
		OrbitCamera3D,
		"Input-driven orbit controller for a Camera3D entity",
	)
	audio_listener_registered := register_builtin_component(
		registry,
		"AudioListener",
		AudioListener,
		"Scene audio reference point, normally attached to the active camera",
	)
	audio_player_registered := register_component(
		registry,
		Component_Descriptor {
			name = "AudioPlayer",
			description = "Named entity sound playback settings",
			allow_multiple = true,
		},
	)
	nav_grid_2d_registered := register_builtin_component(
		registry,
		"NavGrid2D",
		NavGrid2D,
		"Scene-wide 2D navigation grid settings",
	)
	nav_agent_2d_registered := register_builtin_component(
		registry,
		"NavAgent2D",
		NavAgent2D,
		"2D pathfinding agent settings",
	)
	return(
		transform_registered &&
		sprite_registered &&
		mesh_registered &&
		sphere_registered &&
		model_registered &&
		ambient_light_registered &&
		directional_light_registered &&
		point_light_registered &&
		spot_light_registered &&
		tilemap_registered &&
		text_registered &&
		tilemap_collider_registered &&
		top_down_controller_registered &&
		rigid_body_2d_registered &&
		box_collider_2d_registered &&
		circle_collider_2d_registered &&
		rigid_body_3d_registered &&
		box_collider_registered &&
		sphere_collider_registered &&
		character_controller_registered &&
		orbit_registered &&
		rotator_registered &&
		camera_2d_registered &&
		camera_3d_registered &&
		orbit_camera_3d_registered &&
		audio_listener_registered &&
		audio_player_registered &&
		nav_grid_2d_registered &&
		nav_agent_2d_registered \
	)
}

register_builtin_component :: proc(
	registry: ^Component_Registry,
	name: string,
	$T: typeid,
	description: string,
) -> bool {
	return register_component(
		registry,
		Component_Descriptor{name = name, description = description, type_id = typeid_of(T)},
	)
}

// register_component makes a component name available to a World. The component's
// data is deliberately JSON for now: game code owns its behaviour while scenes and
// prefabs remain readable and editable without a reflection system.
register_component_descriptor :: proc(
	registry: ^Component_Registry,
	descriptor: Component_Descriptor,
) -> bool {
	if registry == nil || len(descriptor.name) == 0 || has_component(registry, descriptor.name) {
		return false
	}
	if descriptor.type_id != nil {
		if _, exists := registry.names_by_type[descriptor.type_id]; exists {return false}
		registry.names_by_type[descriptor.type_id] = descriptor.name
	}

	registry.components[descriptor.name] = descriptor
	return true
}

// register_data_component explicitly opts a JSON-only component into a
// registry. Scene loading never invents component types from misspelled names.
register_data_component :: proc(
	registry: ^Component_Registry,
	name: string,
	description := "",
) -> bool {
	return register_component(
		registry,
		Component_Descriptor{name = name, description = description},
	)
}

// register_component_type binds a scene component name to an Odin struct.
// Untagged struct fields use their exact member names as JSON property names;
// `json:"..."` overrides are handled by Odin's JSON reflection support.
// The supplied default value is copied before each deserialize, so omitted JSON
// properties retain their registered defaults.
register_component_type :: proc(
	registry: ^Component_Registry,
	name: string,
	$T: typeid,
	default_value: T,
	description := "",
) -> bool {
	if registry == nil ||
	   registry.typed_defaults_arena == nil ||
	   len(name) == 0 ||
	   has_component(registry, name) ||
	   !is_struct_type(T) {
		return false
	}

	allocator := mem.dynamic_arena_allocator(registry.typed_defaults_arena)
	defaults, allocation_error := mem.new(T, allocator)
	if allocation_error != nil {return false}
	default_bytes, marshal_error := json.marshal(default_value, allocator = allocator)
	if marshal_error != nil ||
	   json.unmarshal(default_bytes, defaults, allocator = allocator) != nil {
		return false
	}

	descriptor := Component_Descriptor {
		name = name,
		description = description,
		type_id = typeid_of(T),
		default_value = any{data = defaults, id = typeid_of(T)},
		create_typed = typed_component_create_proc(T),
	}
	return register_component(registry, descriptor)
}

// register_component is the single public entry point: pass either a low-level
// descriptor or the typed (name, type, defaults, description) arguments.
register_component :: proc {
	register_component_descriptor,
	register_component_type,
}

typed_component_create_proc :: proc($T: typeid) -> Typed_Component_Create_Proc {
	return proc(data: json.Value, default_value: any, allocator: mem.Allocator) -> (any, bool) {
			defaults, defaults_ok := default_value.(T)
			if !defaults_ok || !json_shape_matches_type(data, T) {return nil, false}

			value, allocation_error := mem.new(T, allocator)
			if allocation_error != nil {return nil, false}
			default_bytes, default_marshal_error := json.marshal(defaults, allocator = allocator)
			if default_marshal_error != nil ||
			   json.unmarshal(default_bytes, value, allocator = allocator) != nil {
				return nil, false
			}
			bytes, marshal_error := json.marshal(data, allocator = allocator)
			if marshal_error != nil || json.unmarshal(bytes, value, allocator = allocator) != nil {
				return nil, false
			}
			return any{data = value, id = typeid_of(T)}, true
		}
}

is_struct_type :: proc(component_type: typeid) -> bool {
	type_info := reflect.type_info_base(type_info_of(component_type))
	_, ok := type_info.variant.(reflect.Type_Info_Struct)
	return ok
}

// json_shape_matches_type adds strict unknown-property validation on top of
// core:encoding/json. Missing properties remain valid because registered
// defaults fill them before deserialization.
json_shape_matches_type :: proc(value: json.Value, component_type: typeid) -> bool {
	type_info := reflect.type_info_base(type_info_of(component_type))
	#partial switch info in type_info.variant {
	case reflect.Type_Info_Struct:
		object, object_ok := value.(json.Object)
		if !object_ok {return false}
		for property_name, property_value in object {
			field_type, field_found := json_struct_field_type(component_type, property_name)
			if !field_found || !json_shape_matches_type(property_value, field_type) {return false}
		}
		return true
	case reflect.Type_Info_Array:
		array, array_ok := value.(json.Array)
		if !array_ok || len(array) != info.count {return false}
		for element in array {
			if !json_shape_matches_type(element, info.elem.id) {return false}
		}
		return true
	case reflect.Type_Info_Enumerated_Array:
		array, array_ok := value.(json.Array)
		if !array_ok || len(array) != info.count {return false}
		for element in array {
			if !json_shape_matches_type(element, info.elem.id) {return false}
		}
		return true
	case reflect.Type_Info_Dynamic_Array:
		array, array_ok := value.(json.Array)
		if !array_ok {return false}
		for element in array {
			if !json_shape_matches_type(element, info.elem.id) {return false}
		}
		return true
	case reflect.Type_Info_Slice:
		array, array_ok := value.(json.Array)
		if !array_ok {return false}
		for element in array {
			if !json_shape_matches_type(element, info.elem.id) {return false}
		}
		return true
	case reflect.Type_Info_Map:
		object, object_ok := value.(json.Object)
		if !object_ok {return false}
		for _, element in object {
			if !json_shape_matches_type(element, info.value.id) {return false}
		}
		return true
	case reflect.Type_Info_Pointer:
		if json_value_is_nil(value) {return true}
		return info.elem != nil && json_shape_matches_type(value, info.elem.id)
	}
	// Scalar compatibility is checked by json.unmarshal. This function is
	// concerned with rejecting unknown object properties recursively.
	return true
}

json_struct_field_type :: proc(struct_type: typeid, property_name: string) -> (typeid, bool) {
	for field in reflect.struct_fields_zipped(struct_type) {
		tag_value := reflect.struct_tag_get(field.tag, "json")
		json_name := tag_value
		if comma := strings.index_byte(json_name, ','); comma >= 0 {
			json_name = json_name[:comma]
		}
		if json_name == "-" {continue}
		if json_name == "" {json_name = field.name}
		if property_name == json_name {return field.type.id, true}
	}
	return nil, false
}

has_component :: proc(registry: ^Component_Registry, name: string) -> bool {
	_, found := registry.components[name]
	return found
}

component_descriptor :: proc(
	registry: ^Component_Registry,
	name: string,
) -> (
	Component_Descriptor,
	bool,
) {
	descriptor, found := registry.components[name]
	return descriptor, found
}

component_name_for_type :: proc(registry: ^Component_Registry, $T: typeid) -> (string, bool) {
	name, found := registry.names_by_type[typeid_of(T)]
	return name, found
}
