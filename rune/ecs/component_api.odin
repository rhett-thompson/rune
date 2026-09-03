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
// component. It supports game-owned JSON components as well as built-ins.
entities_with_component :: proc(world: ^World, name: string) -> []Entity {
	components, found := world.component_data[name]
	if !found {return nil}
	result := make([dynamic]Entity, context.temp_allocator)
	for entity in components {
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
	if !is_alive(world, entity) || world.typed_component_arena == nil {return false}
	descriptor, descriptor_found := world.typed_component_descriptors[name]
	if !descriptor_found || descriptor.type_id != typeid_of(T) {return false}
	components, components_found := world.typed_component_data[name]
	if !components_found {
		return false
	}
	if _, value_found := components[entity]; !value_found {return false}

	allocator := mem.dynamic_arena_allocator(world.typed_component_arena)
	replacement, allocation_error := mem.new(T, allocator)
	if allocation_error != nil {return false}
	bytes, marshal_error := json.marshal(value, allocator = allocator)
	if marshal_error != nil || json.unmarshal(bytes, replacement, allocator = allocator) != nil {
		return false
	}
	components[entity] = any {
		data = replacement,
		id   = typeid_of(T),
	}
	world.typed_component_data[name] = components
	record_component_change(world, entity, name, .Changed)
	return true
}

// get is the normal component access path for both built-in and custom typed
// components. The serialized JSON name is resolved from registration once.
get :: proc(world: ^World, entity: Entity, $T: typeid) -> (T, bool) {
	when T == Transform {return get_transform(world, entity)} else when T == SpriteRenderer {return get_sprite_renderer(world, entity)} else when T == MeshRenderer {return get_mesh_renderer(world, entity)} else when T == SphereRenderer {return get_sphere_renderer(world, entity)} else when T == ModelRenderer {return get_model_renderer(world, entity)} else when T == AmbientLight {return get_ambient_light(world, entity)} else when T == DirectionalLight {return get_directional_light(world, entity)} else when T == PointLight {return get_point_light(world, entity)} else when T == SpotLight {return get_spot_light(world, entity)} else when T == TilemapRenderer {return get_tilemap_renderer(world, entity)} else when T == TextRenderer {return get_text_renderer(world, entity)} else when T == TilemapCollider {return get_tilemap_collider(world, entity)} else when T == TopDownController {return get_top_down_controller(world, entity)} else when T == RigidBody2D {return get_rigid_body_2d(world, entity)} else when T == BoxCollider2D {return get_box_collider_2d(world, entity)} else when T == CircleCollider2D {return get_circle_collider_2d(world, entity)} else when T == RigidBody3D {return get_rigid_body_3d(world, entity)} else when T == BoxCollider {return get_box_collider(world, entity)} else when T == SphereCollider {return get_sphere_collider(world, entity)} else when T == CharacterController {return get_character_controller(world, entity)} else when T == Orbit {return get_orbit(world, entity)} else when T == Rotator {return get_rotator(world, entity)} else when T == Camera2D {return get_camera_2d(world, entity)} else when T == Camera3D {return get_camera_3d(world, entity)} else when T == OrbitCamera3D {return get_orbit_camera_3d(world, entity)} else when T == AudioListener {return get_audio_listener(world, entity)} else when T == NavGrid2D {return get_nav_grid_2d(world, entity)} else when T == NavAgent2D {return get_nav_agent_2d(world, entity)} else {
		name, found := world.component_names_by_type[typeid_of(T)]
		if !found {return {}, false}
		return get_typed_component(world, entity, name, T)
	}
}

// set writes a typed component and records a single change version. Systems
// that need reactive work can consume changes_since without file watchers.
set :: proc(world: ^World, entity: Entity, value: $T) -> bool {
	name, registered := world.component_names_by_type[typeid_of(T)]
	if !registered {return false}
	when T == Transform {if !set_transform(world, entity, value) {return false}} else when T == SpriteRenderer {if !set_sprite_renderer(world, entity, value) {return false}} else when T == MeshRenderer {if !set_mesh_renderer(world, entity, value) {return false}} else when T == SphereRenderer {if !set_sphere_renderer(world, entity, value) {return false}} else when T == ModelRenderer {if !set_model_renderer(world, entity, value) {return false}} else when T == AmbientLight {if !set_ambient_light(world, entity, value) {return false}} else when T == DirectionalLight {if !set_directional_light(world, entity, value) {return false}} else when T == PointLight {if !set_point_light(world, entity, value) {return false}} else when T == SpotLight {if !set_spot_light(world, entity, value) {return false}} else when T == TilemapRenderer {if !set_tilemap_renderer(world, entity, value) {return false}} else when T == TextRenderer {if !set_text_renderer(world, entity, value) {return false}} else when T == TilemapCollider {if !set_tilemap_collider(world, entity, value) {return false}} else when T == TopDownController {if !set_top_down_controller(world, entity, value) {return false}} else when T == RigidBody2D {if !set_rigid_body_2d(world, entity, value) {return false}} else when T == BoxCollider2D {
		if !has_component_data(world, entity, name) {return false}
		world.box_colliders_2d[entity] = value
	} else when T == CircleCollider2D {
		if !has_component_data(world, entity, name) {return false}
		world.circle_colliders_2d[entity] = value
	} else when T == RigidBody3D {if !set_rigid_body_3d(world, entity, value) {return false}} else when T == BoxCollider {if !set_box_collider(world, entity, value) {return false}} else when T == SphereCollider {if !set_sphere_collider(world, entity, value) {return false}} else when T == CharacterController {if !set_character_controller(world, entity, value) {return false}} else when T == Orbit {if !set_orbit(world, entity, value) {return false}} else when T == Rotator {if !set_rotator(world, entity, value) {return false}} else when T == Camera2D {if !set_camera_2d(world, entity, value) {return false}} else when T == Camera3D {if !set_camera_3d(world, entity, value) {return false}} else when T == OrbitCamera3D {if !set_orbit_camera_3d(world, entity, value) {return false}} else when T == AudioListener {if !set_audio_listener(world, entity, value) {return false}} else when T == NavGrid2D {if !set_nav_grid_2d(world, entity, value) {return false}} else when T == NavAgent2D {if !set_nav_agent_2d(world, entity, value) {return false}} else {return set_typed_component(world, entity, name, value)}
	record_component_change(world, entity, name, .Changed)
	return true
}

add :: proc(world: ^World, registry: ^Component_Registry, entity: Entity, value: $T) -> bool {
	name, found := component_name_for_type(registry, T)
	if !found {return false}
	return add_typed_component(world, registry, entity, name, value)
}

query :: proc(world: ^World, $T: typeid) -> []Entity {
	name, found := world.component_names_by_type[typeid_of(T)]
	if !found {return nil}
	return entities_with_component(world, name)
}

query2 :: proc(world: ^World, $A: typeid, $B: typeid) -> []Entity {
	name_a, found_a := world.component_names_by_type[typeid_of(A)]
	name_b, found_b := world.component_names_by_type[typeid_of(B)]
	if !found_a || !found_b {return nil}
	result := make([dynamic]Entity, context.temp_allocator)
	for entity in entities_with_component(world, name_a) {
		if has_component_data(world, entity, name_b) {append(&result, entity)}
	}
	return result[:]
}

query3 :: proc(world: ^World, $A: typeid, $B: typeid, $C: typeid) -> []Entity {
	name_a, found_a := world.component_names_by_type[typeid_of(A)]
	name_b, found_b := world.component_names_by_type[typeid_of(B)]
	name_c, found_c := world.component_names_by_type[typeid_of(C)]
	if !found_a || !found_b || !found_c {return nil}
	result := make([dynamic]Entity, context.temp_allocator)
	for entity in entities_with_component(world, name_a) {
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
