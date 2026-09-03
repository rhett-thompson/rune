package ecs

import "core:encoding/json"
import "core:mem"

// set_scene_json stores the full root scene JSON document on the World. Scene
// loading calls this so game code can access scene-owned global settings.
set_scene_json :: proc(world: ^World, value: json.Value) {
	world.scene_json = value
}

// apply_value_snapshot updates metadata and component values from a freshly
// loaded scene while preserving this World's generation and Entity handles.
// It only accepts non-structural edits: the same non-empty scene IDs, parent
// relationships, and component memberships must be present in both Worlds.
apply_value_snapshot :: proc(world: ^World, snapshot: ^World) -> bool {
	entity_translation := make(map[Entity]Entity, context.temp_allocator)
	if !build_snapshot_entity_translation(world, snapshot, &entity_translation) {
		return false
	}
	if !same_parent_shape(world, snapshot, entity_translation) ||
	   !same_component_shape(world.component_data, snapshot.component_data, entity_translation) ||
	   !same_component_instance_shape(
			   world.component_instance_data,
			   snapshot.component_instance_data,
			   entity_translation,
		   ) {
		return false
	}

	for snapshot_entity, target_entity in entity_translation {
		world.entity_names[target_entity] = snapshot.entity_names[snapshot_entity]
		world.entity_tags[target_entity] = snapshot.entity_tags[snapshot_entity]
		world.layer_masks[target_entity] = snapshot.layer_masks[snapshot_entity]
	}

	apply_changed_component_values(world, snapshot, entity_translation)
	apply_changed_component_instance_values(world, snapshot, entity_translation)
	world.scene_json = snapshot.scene_json
	return true
}

build_snapshot_entity_translation :: proc(
	world: ^World,
	snapshot: ^World,
	result: ^map[Entity]Entity,
) -> bool {
	if world.entity_count != snapshot.entity_count ||
	   len(world.entity_ids) != len(snapshot.entity_ids) {
		return false
	}
	for snapshot_entity, id in snapshot.entity_ids {
		if id == "" {return false}
		target_entity, found := world.entities_by_id[id]
		if !found {return false}
		result^[snapshot_entity] = target_entity
	}
	for _, id in world.entity_ids {
		if id == "" {return false}
		if _, found := snapshot.entities_by_id[id]; !found {return false}
	}
	return true
}

same_parent_shape :: proc(
	world: ^World,
	snapshot: ^World,
	entity_translation: map[Entity]Entity,
) -> bool {
	for snapshot_entity, target_entity in entity_translation {
		snapshot_parent, snapshot_has_parent := snapshot.parents[snapshot_entity]
		target_parent, target_has_parent := world.parents[target_entity]
		if snapshot_has_parent != target_has_parent {return false}
		if snapshot_has_parent {
			translated_parent, parent_found := entity_translation[snapshot_parent]
			if !parent_found || translated_parent != target_parent {return false}
		}
	}
	return true
}

same_component_shape :: proc(
	current, snapshot: map[string]map[Entity]json.Value,
	entity_translation: map[Entity]Entity,
) -> bool {
	if len(current) != len(snapshot) {return false}
	for name, snapshot_components in snapshot {
		current_components, found := current[name]
		if !found || len(current_components) != len(snapshot_components) {return false}
		for snapshot_entity in snapshot_components {
			target_entity, entity_found := entity_translation[snapshot_entity]
			if !entity_found {return false}
			if _, component_found := current_components[target_entity];
			   !component_found {return false}
		}
	}
	return true
}

same_component_instance_shape :: proc(
	current, snapshot: map[string]map[Component_Instance]json.Value,
	entity_translation: map[Entity]Entity,
) -> bool {
	if len(current) != len(snapshot) {return false}
	for name, snapshot_instances in snapshot {
		current_instances, found := current[name]
		if !found || len(current_instances) != len(snapshot_instances) {return false}
		for snapshot_key in snapshot_instances {
			target_entity, entity_found := entity_translation[snapshot_key.entity]
			if !entity_found {return false}
			if _, instance_found :=
				   current_instances[Component_Instance{entity = target_entity, name = snapshot_key.name}];
			   !instance_found {
				return false
			}
		}
	}
	return true
}

apply_changed_component_values :: proc(
	world: ^World,
	snapshot: ^World,
	entity_translation: map[Entity]Entity,
) {
	for name, snapshot_components in snapshot.component_data {
		world_components := world.component_data[name]
		for snapshot_entity, snapshot_value in snapshot_components {
			target_entity := entity_translation[snapshot_entity]
			if json_values_equal(world_components[target_entity], snapshot_value) {continue}
			world_components[target_entity] = snapshot_value
			apply_snapshot_component_value(world, snapshot, target_entity, snapshot_entity, name)
			record_component_change(world, target_entity, name, .Changed)
		}
		world.component_data[name] = world_components
	}
}

apply_changed_component_instance_values :: proc(
	world: ^World,
	snapshot: ^World,
	entity_translation: map[Entity]Entity,
) {
	for name, snapshot_instances in snapshot.component_instance_data {
		world_instances := world.component_instance_data[name]
		for snapshot_key, snapshot_value in snapshot_instances {
			target_key := Component_Instance {
				entity = entity_translation[snapshot_key.entity],
				name   = snapshot_key.name,
			}
			if json_values_equal(world_instances[target_key], snapshot_value) {continue}
			world_instances[target_key] = snapshot_value
			if name == "AudioPlayer" {
				world.audio_players[target_key] = snapshot.audio_players[snapshot_key]
			}
			record_component_change(world, target_key.entity, name, .Changed)
		}
		world.component_instance_data[name] = world_instances
	}
}

apply_snapshot_component_value :: proc(
	world: ^World,
	snapshot: ^World,
	target_entity, snapshot_entity: Entity,
	name: string,
) {
	if descriptor, typed := snapshot.typed_component_descriptors[name];
	   typed && descriptor.create_typed != nil {
		if world.typed_component_arena == nil {return}
		allocator := mem.dynamic_arena_allocator(world.typed_component_arena)
		snapshot_components := snapshot.component_data[name]
		replacement, created := descriptor.create_typed(
			snapshot_components[snapshot_entity],
			descriptor.default_value,
			allocator,
		)
		if !created {return}
		components, found := world.typed_component_data[name]
		if !found {components = make(map[Entity]any)}
		components[target_entity] = replacement
		world.typed_component_data[name] = components
		world.typed_component_descriptors[name] = descriptor
		return
	}
	if name == "Transform" {world.transforms[target_entity] = snapshot.transforms[snapshot_entity]}
	if name ==
	   "SpriteRenderer" {world.sprite_renderers[target_entity] = snapshot.sprite_renderers[snapshot_entity]}
	if name ==
	   "MeshRenderer" {world.mesh_renderers[target_entity] = snapshot.mesh_renderers[snapshot_entity]}
	if name ==
	   "SphereRenderer" {world.sphere_renderers[target_entity] = snapshot.sphere_renderers[snapshot_entity]}
	if name ==
	   "ModelRenderer" {world.model_renderers[target_entity] = snapshot.model_renderers[snapshot_entity]}
	if name ==
	   "AmbientLight" {world.ambient_lights[target_entity] = snapshot.ambient_lights[snapshot_entity]}
	if name ==
	   "DirectionalLight" {world.directional_lights[target_entity] = snapshot.directional_lights[snapshot_entity]}
	if name ==
	   "PointLight" {world.point_lights[target_entity] = snapshot.point_lights[snapshot_entity]}
	if name ==
	   "SpotLight" {world.spot_lights[target_entity] = snapshot.spot_lights[snapshot_entity]}
	if name ==
	   "TilemapRenderer" {world.tilemap_renderers[target_entity] = snapshot.tilemap_renderers[snapshot_entity]}
	if name ==
	   "TextRenderer" {world.text_renderers[target_entity] = snapshot.text_renderers[snapshot_entity]}
	if name ==
	   "TilemapCollider" {world.tilemap_colliders[target_entity] = snapshot.tilemap_colliders[snapshot_entity]}
	if name ==
	   "TopDownController" {world.top_down_controllers[target_entity] = snapshot.top_down_controllers[snapshot_entity]}
	if name ==
	   "RigidBody2D" {world.rigid_bodies_2d[target_entity] = snapshot.rigid_bodies_2d[snapshot_entity]}
	if name ==
	   "BoxCollider2D" {world.box_colliders_2d[target_entity] = snapshot.box_colliders_2d[snapshot_entity]}
	if name ==
	   "CircleCollider2D" {world.circle_colliders_2d[target_entity] = snapshot.circle_colliders_2d[snapshot_entity]}
	if name ==
	   "RigidBody3D" {world.rigid_bodies_3d[target_entity] = snapshot.rigid_bodies_3d[snapshot_entity]}
	if name ==
	   "BoxCollider" {world.box_colliders[target_entity] = snapshot.box_colliders[snapshot_entity]}
	if name ==
	   "SphereCollider" {world.sphere_colliders[target_entity] = snapshot.sphere_colliders[snapshot_entity]}
	if name ==
	   "CharacterController" {world.character_controllers[target_entity] = snapshot.character_controllers[snapshot_entity]}
	if name == "Orbit" {world.orbits[target_entity] = snapshot.orbits[snapshot_entity]}
	if name == "Rotator" {world.rotators[target_entity] = snapshot.rotators[snapshot_entity]}
	if name == "Camera2D" {world.cameras_2d[target_entity] = snapshot.cameras_2d[snapshot_entity]}
	if name == "Camera3D" {world.cameras_3d[target_entity] = snapshot.cameras_3d[snapshot_entity]}
	if name ==
	   "OrbitCamera3D" {world.orbit_cameras_3d[target_entity] = snapshot.orbit_cameras_3d[snapshot_entity]}
	if name ==
	   "AudioListener" {world.audio_listeners[target_entity] = snapshot.audio_listeners[snapshot_entity]}
	if name ==
	   "NavGrid2D" {world.nav_grids_2d[target_entity] = snapshot.nav_grids_2d[snapshot_entity]}
	if name ==
	   "NavAgent2D" {world.nav_agents_2d[target_entity] = snapshot.nav_agents_2d[snapshot_entity]}
}

json_values_equal :: proc(left, right: json.Value) -> bool {
	#partial switch left_value in left {
	case nil:
		return json_value_is_nil(right)
	case bool:
		right_value, ok := right.(bool)
		return ok && left_value == right_value
	case string:
		right_value, ok := right.(string)
		return ok && left_value == right_value
	case json.Integer:
		if right_value, ok := right.(json.Integer); ok {return left_value == right_value}
		if right_value, ok := right.(json.Float); ok {return f64(left_value) == f64(right_value)}
		return false
	case json.Float:
		if right_value, ok := right.(json.Float); ok {return left_value == right_value}
		if right_value, ok := right.(json.Integer); ok {return f64(left_value) == f64(right_value)}
		return false
	case json.Array:
		right_value, ok := right.(json.Array)
		if !ok || len(left_value) != len(right_value) {return false}
		for value, index in left_value {
			if !json_values_equal(value, right_value[index]) {return false}
		}
		return true
	case json.Object:
		right_value, ok := right.(json.Object)
		if !ok || len(left_value) != len(right_value) {return false}
		for key, value in left_value {
			right_field, found := right_value[key]
			if !found || !json_values_equal(value, right_field) {return false}
		}
		return true
	}
	return false
}

json_value_is_nil :: proc(value: json.Value) -> bool {
	#partial switch _ in value {
	case nil:
		return true
	}
	return false
}

// get_scene_json exposes the full root scene JSON document used to create this
// World, including game-defined fields outside the entity list.
get_scene_json :: proc(world: ^World) -> json.Value {return world.scene_json}

// get_scene_value returns a top-level scene JSON value by key.
get_scene_value :: proc(world: ^World, key: string) -> (json.Value, bool) {
	object, ok := world.scene_json.(json.Object)
	if !ok {return {}, false}
	value, found := object[key]
	return value, found
}
