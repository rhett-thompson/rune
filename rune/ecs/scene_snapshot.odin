package ecs

import "core:encoding/json"
import "core:mem"
import "core:strings"

// set_scene_json stores the full root scene JSON document on the World. Scene
// loading calls this so game code can access scene-owned global settings.
set_scene_json :: proc(world: ^World, value: json.Value) {
	world.scene_json = json.clone_value(value, scene_data_allocator(world))
}

scene_data_allocator :: proc(world: ^World) -> mem.Allocator {
	return mem.dynamic_arena_allocator(world.scene_data_arena)
}

retain_scene_string :: proc(world: ^World, value: string) -> string {
	if len(value) == 0 {return ""}
	if owned, found := world.scene_strings[value]; found {return owned}
	owned, _ := strings.clone(value, scene_data_allocator(world))
	world.scene_strings[owned] = owned
	return owned
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
	adopt_snapshot_storage(world, snapshot, entity_translation)
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
	if descriptor, typed := snapshot.component_descriptors[name];
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
		world.component_descriptors[name] = descriptor
		record_component_change(world, target_entity, name, .Changed)
		return
	}
	switch name {
	case "Transform":
		commit_component_value(world, target_entity, name, &world.transforms, snapshot.transforms[snapshot_entity])
	case "SpriteRenderer":
		commit_component_value(world, target_entity, name, &world.sprite_renderers, snapshot.sprite_renderers[snapshot_entity])
	case "SpriteAnimator":
		commit_component_value(world, target_entity, name, &world.sprite_animators, snapshot.sprite_animators[snapshot_entity])
	case "MeshRenderer":
		commit_component_value(world, target_entity, name, &world.mesh_renderers, snapshot.mesh_renderers[snapshot_entity])
	case "SphereRenderer":
		commit_component_value(world, target_entity, name, &world.sphere_renderers, snapshot.sphere_renderers[snapshot_entity])
	case "ModelRenderer":
		value := clone_model_renderer_storage(snapshot.model_renderers[snapshot_entity])
		destroy_model_renderer_storage(world.model_renderers[target_entity])
		commit_component_value(world, target_entity, name, &world.model_renderers, value)
	case "AmbientLight":
		commit_component_value(world, target_entity, name, &world.ambient_lights, snapshot.ambient_lights[snapshot_entity])
	case "DirectionalLight":
		commit_component_value(world, target_entity, name, &world.directional_lights, snapshot.directional_lights[snapshot_entity])
	case "PointLight":
		commit_component_value(world, target_entity, name, &world.point_lights, snapshot.point_lights[snapshot_entity])
	case "SpotLight":
		commit_component_value(world, target_entity, name, &world.spot_lights, snapshot.spot_lights[snapshot_entity])
	case "TilemapRenderer":
		value := clone_tilemap_renderer_storage(snapshot.tilemap_renderers[snapshot_entity])
		destroy_tilemap_renderer_storage(world.tilemap_renderers[target_entity])
		commit_component_value(world, target_entity, name, &world.tilemap_renderers, value)
	case "TextRenderer":
		commit_component_value(world, target_entity, name, &world.text_renderers, snapshot.text_renderers[snapshot_entity])
	case "TilemapCollider":
		value := clone_tilemap_collider_storage(snapshot.tilemap_colliders[snapshot_entity])
		destroy_tilemap_collider_storage(world.tilemap_colliders[target_entity])
		commit_component_value(world, target_entity, name, &world.tilemap_colliders, value)
	case "TopDownController":
		commit_component_value(world, target_entity, name, &world.top_down_controllers, snapshot.top_down_controllers[snapshot_entity])
	case "RigidBody2D":
		commit_component_value(world, target_entity, name, &world.rigid_bodies_2d, preserve_simulation_state(world, target_entity, snapshot.rigid_bodies_2d[snapshot_entity]))
	case "BoxCollider2D":
		commit_component_value(world, target_entity, name, &world.box_colliders_2d, snapshot.box_colliders_2d[snapshot_entity])
	case "CircleCollider2D":
		commit_component_value(world, target_entity, name, &world.circle_colliders_2d, snapshot.circle_colliders_2d[snapshot_entity])
	case "RigidBody3D":
		commit_component_value(world, target_entity, name, &world.rigid_bodies_3d, snapshot.rigid_bodies_3d[snapshot_entity])
	case "BoxCollider":
		commit_component_value(world, target_entity, name, &world.box_colliders, snapshot.box_colliders[snapshot_entity])
	case "SphereCollider":
		commit_component_value(world, target_entity, name, &world.sphere_colliders, snapshot.sphere_colliders[snapshot_entity])
	case "CharacterController":
		commit_component_value(world, target_entity, name, &world.character_controllers, preserve_simulation_state(world, target_entity, snapshot.character_controllers[snapshot_entity]))
	case "Orbit":
		commit_component_value(world, target_entity, name, &world.orbits, snapshot.orbits[snapshot_entity])
	case "Rotator":
		commit_component_value(world, target_entity, name, &world.rotators, snapshot.rotators[snapshot_entity])
	case "Camera2D":
		commit_component_value(world, target_entity, name, &world.cameras_2d, snapshot.cameras_2d[snapshot_entity])
	case "CameraFollow2D":
		commit_component_value(world, target_entity, name, &world.camera_follows_2d, snapshot.camera_follows_2d[snapshot_entity])
	case "Camera3D":
		commit_component_value(world, target_entity, name, &world.cameras_3d, snapshot.cameras_3d[snapshot_entity])
	case "OrbitCamera3D":
		commit_component_value(world, target_entity, name, &world.orbit_cameras_3d, snapshot.orbit_cameras_3d[snapshot_entity])
	case "AudioListener":
		commit_component_value(world, target_entity, name, &world.audio_listeners, snapshot.audio_listeners[snapshot_entity])
	case "NavGrid2D":
		commit_component_value(world, target_entity, name, &world.nav_grids_2d, snapshot.nav_grids_2d[snapshot_entity])
	case "NavAgent2D":
		commit_component_value(world, target_entity, name, &world.nav_agents_2d, snapshot.nav_agents_2d[snapshot_entity])
	case:
		record_component_change(world, target_entity, name, .Changed)
	}
}

clone_model_renderer_storage :: proc(value: ModelRenderer) -> ModelRenderer {
	result := value
	if value.materials != nil {
		result.materials = make(map[i32]string)
		for slot, path in value.materials {result.materials[slot] = path}
	}
	return result
}

clone_tilemap_renderer_storage :: proc(value: TilemapRenderer) -> TilemapRenderer {
	result := value
	if value.tiles != nil {
		result.tiles = make([]Tilemap_Tile, len(value.tiles))
		copy(result.tiles, value.tiles)
	}
	if value.tile_indices != nil {
		result.tile_indices = make(map[[2]i32]i32)
		for cell, tile in value.tile_indices {result.tile_indices[cell] = tile}
	}
	if value.tile_sizes != nil {
		result.tile_sizes = make(map[i32][2]i32)
		for tile, size in value.tile_sizes {result.tile_sizes[tile] = size}
	}
	if value.tile_collisions != nil {
		result.tile_collisions = make(map[i32]Tilemap_Collision_Rect)
		for tile, collision in value.tile_collisions {
			result.tile_collisions[tile] = collision
		}
	}
	return result
}

clone_tilemap_collider_storage :: proc(value: TilemapCollider) -> TilemapCollider {
	result := value
	if value.solid_tiles != nil {
		result.solid_tiles = make(map[i32]bool)
		for tile, solid in value.solid_tiles {result.solid_tiles[tile] = solid}
	}
	return result
}

destroy_model_renderer_storage :: proc(value: ModelRenderer) {
	if value.materials != nil {delete(value.materials)}
}

destroy_tilemap_renderer_storage :: proc(value: TilemapRenderer) {
	if value.tiles != nil {delete(value.tiles)}
	if value.tile_indices != nil {delete(value.tile_indices)}
	if value.tile_sizes != nil {delete(value.tile_sizes)}
	if value.tile_collisions != nil {delete(value.tile_collisions)}
}

destroy_tilemap_collider_storage :: proc(value: TilemapCollider) {
	if value.solid_tiles != nil {delete(value.solid_tiles)}
}

adopt_snapshot_storage :: proc(world, snapshot: ^World, entity_translation: map[Entity]Entity) {
	rehome_entity_metadata(world, snapshot, entity_translation)
	rehome_component_json(world, snapshot, entity_translation)
	rehome_component_instance_json(world, snapshot, entity_translation)
	rehome_component_map_names(world, snapshot)
	rehome_builtin_strings(world, snapshot)

	old_arena := world.scene_data_arena
	delete(world.scene_strings)
	world.scene_strings = snapshot.scene_strings
	world.scene_data_arena = snapshot.scene_data_arena
	snapshot.scene_strings = nil
	snapshot.scene_data_arena = nil
	if old_arena != nil {
		mem.dynamic_arena_destroy(old_arena)
		mem.free(old_arena)
	}
}

rehome_entity_metadata :: proc(world, snapshot: ^World, entity_translation: map[Entity]Entity) {
	entity_ids := make(map[Entity]string)
	entities_by_id := make(map[string]Entity)
	entity_names := make(map[Entity]string)
	entity_tags := make(map[Entity]string)
	for snapshot_entity, target_entity in entity_translation {
		id := retain_scene_string(snapshot, snapshot.entity_ids[snapshot_entity])
		name := retain_scene_string(snapshot, snapshot.entity_names[snapshot_entity])
		tag := retain_scene_string(snapshot, snapshot.entity_tags[snapshot_entity])
		entity_ids[target_entity] = id
		entity_names[target_entity] = name
		entity_tags[target_entity] = tag
		if len(id) > 0 {entities_by_id[id] = target_entity}
	}
	delete(world.entity_ids)
	delete(world.entities_by_id)
	delete(world.entity_names)
	delete(world.entity_tags)
	world.entity_ids = entity_ids
	world.entities_by_id = entities_by_id
	world.entity_names = entity_names
	world.entity_tags = entity_tags
}

rehome_component_json :: proc(world, snapshot: ^World, entity_translation: map[Entity]Entity) {
	component_data := make(map[string]map[Entity]json.Value)
	for name, snapshot_components in snapshot.component_data {
		owned_name := retain_scene_string(snapshot, name)
		components := make(map[Entity]json.Value)
		for snapshot_entity, value in snapshot_components {
			components[entity_translation[snapshot_entity]] = value
		}
		component_data[owned_name] = components
	}
	for _, components in world.component_data {delete(components)}
	delete(world.component_data)
	world.component_data = component_data
}

rehome_component_instance_json :: proc(
	world, snapshot: ^World,
	entity_translation: map[Entity]Entity,
) {
	instance_data := make(map[string]map[Component_Instance]json.Value)
	for name, snapshot_instances in snapshot.component_instance_data {
		owned_name := retain_scene_string(snapshot, name)
		instances := make(map[Component_Instance]json.Value)
		for snapshot_key, value in snapshot_instances {
			key := Component_Instance {
				entity = entity_translation[snapshot_key.entity],
				name   = retain_scene_string(snapshot, snapshot_key.name),
			}
			instances[key] = value
		}
		instance_data[owned_name] = instances
	}
	for _, instances in world.component_instance_data {delete(instances)}
	delete(world.component_instance_data)
	world.component_instance_data = instance_data
}

rehome_component_map_names :: proc(world, snapshot: ^World) {
	typed_data := make(map[string]map[Entity]any)
	for name, components in world.typed_component_data {
		typed_data[retain_scene_string(snapshot, name)] = components
	}
	delete(world.typed_component_data)
	world.typed_component_data = typed_data

	descriptors := make(map[string]Component_Descriptor)
	for name, descriptor in world.component_descriptors {
		descriptors[retain_scene_string(snapshot, name)] = descriptor
	}
	delete(world.component_descriptors)
	world.component_descriptors = descriptors

	names_by_type := make(map[typeid]string)
	for id, name in world.component_names_by_type {
		names_by_type[id] = retain_scene_string(snapshot, name)
	}
	delete(world.component_names_by_type)
	world.component_names_by_type = names_by_type

	changes := make(map[Component_Change_Key]Component_Change)
	for key, change in world.component_changes {
		owned_key := key
		owned_key.name = retain_scene_string(snapshot, key.name)
		changes[owned_key] = change
	}
	delete(world.component_changes)
	world.component_changes = changes
}

rehome_builtin_strings :: proc(world, snapshot: ^World) {
	for entity, value in world.sprite_renderers {
		owned := value
		owned.texture = retain_scene_string(snapshot, value.texture)
		world.sprite_renderers[entity] = owned
	}
	for entity, value in world.sprite_animators {
		owned := value
		owned.animation = retain_scene_string(snapshot, value.animation)
		owned.clip = retain_scene_string(snapshot, value.clip)
		world.sprite_animators[entity] = owned
	}
	for entity, value in world.mesh_renderers {
		owned := value
		owned.primitive = retain_scene_string(snapshot, value.primitive)
		owned.material = retain_scene_string(snapshot, value.material)
		world.mesh_renderers[entity] = owned
	}
	for entity, value in world.sphere_renderers {
		owned := value
		owned.material = retain_scene_string(snapshot, value.material)
		world.sphere_renderers[entity] = owned
	}
	for entity, value in world.model_renderers {
		owned := value
		owned.model = retain_scene_string(snapshot, value.model)
		owned.material = retain_scene_string(snapshot, value.material)
		for slot, path in owned.materials {
			owned.materials[slot] = retain_scene_string(snapshot, path)
		}
		world.model_renderers[entity] = owned
	}
	for entity, value in world.tilemap_renderers {
		owned := value
		owned.tileset = retain_scene_string(snapshot, value.tileset)
		owned.texture = retain_scene_string(snapshot, value.texture)
		world.tilemap_renderers[entity] = owned
	}
	for entity, value in world.text_renderers {
		owned := value
		owned.text = retain_scene_string(snapshot, value.text)
		owned.font = retain_scene_string(snapshot, value.font)
		world.text_renderers[entity] = owned
	}
	for entity, value in world.rigid_bodies_2d {
		owned := value
		owned.body_type = retain_scene_string(snapshot, value.body_type)
		world.rigid_bodies_2d[entity] = owned
	}
	for entity, value in world.rigid_bodies_3d {
		owned := value
		owned.body_type = retain_scene_string(snapshot, value.body_type)
		world.rigid_bodies_3d[entity] = owned
	}
	for entity, value in world.orbit_cameras_3d {
		owned := value
		owned.manual_action = retain_scene_string(snapshot, value.manual_action)
		owned.yaw_axis = retain_scene_string(snapshot, value.yaw_axis)
		owned.pitch_axis = retain_scene_string(snapshot, value.pitch_axis)
		owned.zoom_axis = retain_scene_string(snapshot, value.zoom_axis)
		world.orbit_cameras_3d[entity] = owned
	}
	for entity, value in world.camera_follows_2d {
		owned := value
		owned.target.id = retain_scene_string(snapshot, value.target.id)
		world.camera_follows_2d[entity] = owned
	}
	audio_players := make(map[Component_Instance]AudioPlayer)
	for key, value in world.audio_players {
		owned_key := key
		owned_value := value
		owned_key.name = retain_scene_string(snapshot, key.name)
		owned_value.sound = retain_scene_string(snapshot, value.sound)
		audio_players[owned_key] = owned_value
	}
	delete(world.audio_players)
	world.audio_players = audio_players
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
