package ecs

import "core:encoding/json"
import "core:mem"

has_component_data :: proc(world: ^World, entity: Entity, name: string) -> bool {
	components, found := world.component_data[name]
	if !found {
		return false
	}
	_, component_found := components[entity]
	return component_found
}

// entities_with_component returns the entities currently carrying a named
// component. Disabled entities are omitted unless include_disabled is true.
// Direct get/set and has_component_data still work on disabled entities.
entities_with_component :: proc(world: ^World, name: string, include_disabled := false) -> []Entity {
	components, found := world.component_data[name]
	if !found {return nil}
	result := make([dynamic]Entity, context.temp_allocator)
	for entity in components {
		if !include_disabled && !is_enabled(world, entity) {continue}
		append(&result, entity)
	}
	return result[:]
}

get_component :: proc(world: ^World, entity: Entity, name: string) -> (json.Value, bool) {
	components, found := world.component_data[name]
	if !found {
		return {}, false
	}

	component, component_found := components[entity]
	return component, component_found
}

// get_typed_component returns a copy of a registered custom component struct.
// Reference fields are borrowed and read-only until the next successful write,
// removal, or reload of that component (or World destruction). Set copies them.
// Call set_typed_component after changing it so the World remains the mutation
// boundary for future change tracking and reactive systems.
get_typed_component :: proc(world: ^World, entity: Entity, name: string, $T: typeid) -> (T, bool) {
	components, found := world.typed_component_data[name]
	if !found {return {}, false}
	value, value_found := components[entity]
	if !value_found || value.id != typeid_of(T) {return {}, false}
	return (^T)(value.data)^, true
}

set_typed_component :: proc(world: ^World, entity: Entity, name: string, value: $T) -> bool {
	when T == NavMesh3D || T == NavAgent3D || T == Interactable3D || T == Interactor3D {if !component_value_valid(value) {return false}}
	if !is_alive(world, entity) || world.typed_component_arena == nil {return false}
	descriptor, descriptor_found := world.component_descriptors[name]
	if !descriptor_found || descriptor.type_id != typeid_of(T) {return false}
	components, components_found := world.typed_component_data[name]
	if !components_found {
		return false
	}
	previous, value_found := components[entity]
	if !value_found || previous.id != typeid_of(T) {return false}
	if descriptor.copy_value {
		candidate := value
		if !typed_copy_value_valid(&candidate, type_info_of(T)) {return false}
		(^T)(previous.data)^ = value
		record_component_change(world, entity, name, .Changed)
		return true
	}

	// JSON conversion handles ownership of strings, slices and maps.
	// Its output belongs only to this value, never to the scene-lifetime arena.
	bytes, marshal_error := json.marshal(value)
	defer delete(bytes)
	if marshal_error != nil {return false}
	arena := new_typed_value_arena()
	if arena == nil {return false}
	allocator := mem.dynamic_arena_allocator(arena)
	replacement, allocation_error := mem.new(T, allocator)
	if allocation_error != nil || json.unmarshal(bytes, replacement, allocator = allocator) != nil {
		destroy_typed_value_arena(arena)
		return false
	}
	// The named API may receive a name borrowed from the old component too.
	owned_name := retain_scene_string(world, name)
	release_typed_value(world, previous)
	world.typed_value_arenas[replacement] = arena
	components[entity] = any {
		data = replacement,
		id   = typeid_of(T),
	}
	world.typed_component_data[owned_name] = components
	record_component_change(world, entity, owned_name, .Changed)
	return true
}

// get is the normal component access path for both built-in and custom typed
// components. The serialized JSON name is resolved from registration once.
get :: proc(world: ^World, entity: Entity, $T: typeid) -> (T, bool) {
	when T == Terrain {return get_terrain(world,entity)}
	when T == Skybox {return get_skybox(world, entity)}
	when T == PostProcessing {return get_post_processing(world, entity)}
	when T == ParticleEmitter2D {
		return get_particle_emitter_2d(world, entity)
	} else when T == Lifetime {
		return get_lifetime(world, entity)
	} else when T == ShapeRenderer2D {
		return get_shape_renderer_2d(world, entity)
	}
	else when T == Transform {
		return get_transform(world, entity)
	}
	else when T == SpriteRenderer {
		return get_sprite_renderer(world, entity)
	}
	else when T == ModelAnimator {
		return get_model_animator(world, entity)
	}
	else when T == SpriteAnimator {
		return get_sprite_animator(world, entity)
	}
	else when T == MeshRenderer {
		return get_mesh_renderer(world, entity)
	}
	else when T == SphereRenderer {
		return get_sphere_renderer(world, entity)
	}
	else when T == ModelRenderer {
		return get_model_renderer(world, entity)
	}
	else when T == AmbientLight {
		return get_ambient_light(world, entity)
	}
	else when T == DirectionalLight {
		return get_directional_light(world, entity)
	}
	else when T == PointLight {
		return get_point_light(world, entity)
	}
	else when T == SpotLight {
		return get_spot_light(world, entity)
	}
	else when T == TilemapRenderer {
		return get_tilemap_renderer(world, entity)
	}
	else when T == TextRenderer {
		return get_text_renderer(world, entity)
	}
	else when T == TilemapCollider {
		return get_tilemap_collider(world, entity)
	}
	else when T == TopDownController {
		return get_top_down_controller(world, entity)
	}
	else when T == RigidBody2D {
		return get_rigid_body_2d(world, entity)
	}
	else when T == BoxCollider2D {
		return get_box_collider_2d(world, entity)
	}
	else when T == CircleCollider2D {
		return get_circle_collider_2d(world, entity)
	} else when T == CapsuleCollider2D {
		return get_capsule_collider_2d(world, entity)
	} else when T == CharacterController3D {
		return get_character_controller_3d(world, entity)
	} else when T == CharacterController2D {
		return get_character_controller_2d(world, entity)
	} else when T == PolygonCollider2D {
		return get_polygon_collider_2d(world, entity)
	} else when T == SegmentCollider2D {
		return get_segment_collider_2d(world, entity)
	}
	else when T == RigidBody3D {
		return get_rigid_body_3d(world, entity)
	}
	else when T == BoxCollider {
		return get_box_collider(world, entity)
	}
	else when T == SphereCollider {
		return get_sphere_collider(world, entity)
	}
	else when T == CharacterController {
		return get_character_controller(world, entity)
	}
	else when T == Orbit {
		return get_orbit(world, entity)
	}
	else when T == Rotator {
		return get_rotator(world, entity)
	}
	else when T == Camera2D {
		return get_camera_2d(world, entity)
	}
	else when T == CameraFollow2D {
		return get_camera_follow_2d(world, entity)
	}
	else when T == Camera3D {
		return get_camera_3d(world, entity)
	}
	else when T == OrbitCamera3D {
		return get_orbit_camera_3d(world, entity)
	}
	else when T == AudioListener {
		return get_audio_listener(world, entity)
	}
	else when T == NavGrid2D {
		return get_nav_grid_2d(world, entity)
	}
	else when T == NavAgent2D {
		return get_nav_agent_2d(world, entity)
	}
	else {
		name, found := world.component_names_by_type[typeid_of(T)]
		if !found {return {}, false}
		return get_typed_component(world, entity, name, T)
	}
}

// set writes a typed component and records a single change version. Systems
// that need reactive work can consume changes_since without file watchers.
set :: proc(world: ^World, entity: Entity, value: $T) -> bool {
	when T == Terrain {return set_terrain(world,entity,value)}
	when T == Skybox {return set_skybox(world, entity, value)}
	when T == PostProcessing {return set_post_processing(world, entity, value)}
	name, registered := world.component_names_by_type[typeid_of(T)]
	if !registered {return false}
	when T == ParticleEmitter2D {
		return set_particle_emitter_2d(world, entity, value)
	} else when T == Lifetime {
		return set_lifetime(world, entity, value)
	} else when T == ShapeRenderer2D {
		return set_shape_renderer_2d(world, entity, value)
	}
	else when T == Transform {
		return set_transform(world, entity, value)
	}
	else when T == SpriteRenderer {
		return set_sprite_renderer(world, entity, value)
	}
	else when T == ModelAnimator {
		return set_model_animator(world, entity, value)
	}
	else when T == SpriteAnimator {
		return set_sprite_animator(world, entity, value)
	}
	else when T == MeshRenderer {
		return set_mesh_renderer(world, entity, value)
	}
	else when T == SphereRenderer {
		return set_sphere_renderer(world, entity, value)
	}
	else when T == ModelRenderer {
		return set_model_renderer(world, entity, value)
	}
	else when T == AmbientLight {
		return set_ambient_light(world, entity, value)
	}
	else when T == DirectionalLight {
		return set_directional_light(world, entity, value)
	}
	else when T == PointLight {
		return set_point_light(world, entity, value)
	}
	else when T == SpotLight {
		return set_spot_light(world, entity, value)
	}
	else when T == TilemapRenderer {
		return set_tilemap_renderer(world, entity, value)
	}
	else when T == TextRenderer {
		return set_text_renderer(world, entity, value)
	}
	else when T == TilemapCollider {
		return set_tilemap_collider(world, entity, value)
	}
	else when T == TopDownController {
		return set_top_down_controller(world, entity, value)
	}
	else when T == RigidBody2D {
		return set_rigid_body_2d(world, entity, value)
	}
	else when T == BoxCollider2D {
		return set_box_collider_2d(world, entity, value)
	}
	else when T == CircleCollider2D {
		return set_circle_collider_2d(world, entity, value)
	} else when T == CapsuleCollider2D {
		return set_capsule_collider_2d(world, entity, value)
	} else when T == CharacterController3D {
		return set_character_controller_3d(world, entity, value)
	} else when T == CharacterController2D {
		return set_character_controller_2d(world, entity, value)
	} else when T == PolygonCollider2D {
		return set_polygon_collider_2d(world, entity, value)
	} else when T == SegmentCollider2D {
		return set_segment_collider_2d(world, entity, value)
	}
	else when T == RigidBody3D {
		return set_rigid_body_3d(world, entity, value)
	}
	else when T == BoxCollider {
		return set_box_collider(world, entity, value)
	}
	else when T == SphereCollider {
		return set_sphere_collider(world, entity, value)
	}
	else when T == CharacterController {
		return set_character_controller(world, entity, value)
	}
	else when T == Orbit {
		return set_orbit(world, entity, value)
	}
	else when T == Rotator {
		return set_rotator(world, entity, value)
	}
	else when T == Camera2D {
		return set_camera_2d(world, entity, value)
	}
	else when T == CameraFollow2D {
		return set_camera_follow_2d(world, entity, value)
	}
	else when T == Camera3D {
		return set_camera_3d(world, entity, value)
	}
	else when T == OrbitCamera3D {
		return set_orbit_camera_3d(world, entity, value)
	}
	else when T == AudioListener {
		return set_audio_listener(world, entity, value)
	}
	else when T == NavGrid2D {
		return set_nav_grid_2d(world, entity, value)
	}
	else when T == NavAgent2D {
		return set_nav_agent_2d(world, entity, value)
	}
	else {return set_typed_component(world, entity, name, value)}
}

add :: proc(world: ^World, registry: ^Component_Registry, entity: Entity, value: $T) -> bool {
	when T == Terrain {
		if !terrain_valid(value) {return false}
		data,ok := runtime_json(value)
		return ok && add_component(world,registry,entity,"Terrain",data)
	}
	when T == Skybox {
		if !skybox_valid(value) {return false}
		data, ok := skybox_json(value)
		return ok && add_component(world, registry, entity, "Skybox", data)
	}
	when T == PostProcessing {
		if !post_processing_valid(value) {return false}
		data, ok := post_processing_json(value)
		return ok && add_component(world, registry, entity, "PostProcessing", data)
	}
	when T == CapsuleCollider2D || T == BoxCollider2D || T == CircleCollider2D || T == PolygonCollider2D || T == SegmentCollider2D || T == CharacterController2D || T == CharacterController3D {
		if !component_value_valid(value) {return false}
		collider_name, registered := component_name_for_type(registry, T)
		if !registered {return false}
		data, ok := runtime_json(value)
		if !ok {return false}
		when T == CapsuleCollider2D {
			object := data.(json.Object)
			object["axis"] = json.String("vertical" if value.axis == .vertical else "horizontal")
		}
		return add_component(world, registry, entity, collider_name, data)
	}
	when T == ShapeRenderer2D || T == Lifetime {
		if !component_value_valid(value) {return false}
		data, ok := runtime_json(value)
		when T == ShapeRenderer2D {
			object := data.(json.Object)
			object["shape"] = json.String("rectangle" if value.shape == .rectangle else "circle")
			object["color"], _ = runtime_json([4]u8{value.color.r, value.color.g, value.color.b, value.color.a})
			return ok && add_component(world, registry, entity, "ShapeRenderer2D", object)
		} else {return ok && add_component(world, registry, entity, "Lifetime", data)}
	}

	when T == ParticleEmitter2D {
		if !component_value_valid(value) {return false}
		data, ok := runtime_json(value)
		return ok && add_component(world, registry, entity, "ParticleEmitter2D", data)
	}
	name, found := component_name_for_type(registry, T)
	if !found {return false}
	return add_typed_component(world, registry, entity, name, value)
}

query :: proc(world: ^World, $T: typeid, include_disabled := false) -> []Entity {
	name, found := world.component_names_by_type[typeid_of(T)]
	if !found {return nil}
	return entities_with_component(world, name, include_disabled)
}

query2 :: proc(world: ^World, $A: typeid, $B: typeid, include_disabled := false) -> []Entity {
	name_a, found_a := world.component_names_by_type[typeid_of(A)]
	name_b, found_b := world.component_names_by_type[typeid_of(B)]
	if !found_a || !found_b {return nil}
	result := make([dynamic]Entity, context.temp_allocator)
	for entity in entities_with_component(world, name_a, include_disabled) {
		if has_component_data(world, entity, name_b) {append(&result, entity)}
	}
	return result[:]
}

query3 :: proc(world: ^World, $A: typeid, $B: typeid, $C: typeid, include_disabled := false) -> []Entity {
	name_a, found_a := world.component_names_by_type[typeid_of(A)]
	name_b, found_b := world.component_names_by_type[typeid_of(B)]
	name_c, found_c := world.component_names_by_type[typeid_of(C)]
	if !found_a || !found_b || !found_c {return nil}
	result := make([dynamic]Entity, context.temp_allocator)
	for entity in entities_with_component(world, name_a, include_disabled) {
		if has_component_data(world, entity, name_b) && has_component_data(world, entity, name_c) {
			append(&result, entity)
		}
	}
	return result[:]
}

change_version :: proc(world: ^World) -> u64 {return world.component_change_version}

changes_since :: proc(world: ^World, $T: typeid, version: u64) -> []Component_Change {
	name, found := world.component_names_by_type[typeid_of(T)]
	if !found {return nil}
	result := make([dynamic]Component_Change, context.temp_allocator)
	for key, change in world.component_changes {
		if key.name == name && change.version > version {append(&result, change)}
	}
	return result[:]
}
