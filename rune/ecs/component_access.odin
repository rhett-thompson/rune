package ecs

// get_transform gives game systems typed Transform data for an entity. Call
// set_transform after changing the returned value.
get_transform :: proc(world: ^World, entity: Entity) -> (Transform, bool) {
	transform, found := world.transforms[entity]
	return transform, found
}

set_transform :: proc(world: ^World, entity: Entity, transform: Transform) -> bool {
	if !is_alive(world, entity) || !has_component_data(world, entity, "Transform") {
		return false
	}

	world.transforms[entity] = transform
	return true
}

get_sprite_renderer :: proc(
	world: ^World,
	entity: Entity,
) -> (
	SpriteRenderer,
	bool,
) {value, found := world.sprite_renderers[entity]; return value, found}
set_sprite_renderer :: proc(
	world: ^World,
	entity: Entity,
	value: SpriteRenderer,
) -> bool {if !has_component_data(world, entity, "SpriteRenderer") {return false}
	owned := value
	owned.texture = retain_scene_string(world, value.texture)
	world.sprite_renderers[entity] = owned
	return true}
get_mesh_renderer :: proc(world: ^World, entity: Entity) -> (MeshRenderer, bool) {value, found :=
		world.mesh_renderers[entity]
	return value, found}
set_mesh_renderer :: proc(
	world: ^World,
	entity: Entity,
	value: MeshRenderer,
) -> bool {if !has_component_data(world, entity, "MeshRenderer") {return false}
	owned := value
	owned.primitive = retain_scene_string(world, value.primitive)
	owned.material = retain_scene_string(world, value.material)
	world.mesh_renderers[entity] = owned
	return true}
get_sphere_renderer :: proc(
	world: ^World,
	entity: Entity,
) -> (
	SphereRenderer,
	bool,
) {value, found := world.sphere_renderers[entity]; return value, found}
set_sphere_renderer :: proc(
	world: ^World,
	entity: Entity,
	value: SphereRenderer,
) -> bool {if !has_component_data(world, entity, "SphereRenderer") {return false}
	owned := value
	owned.material = retain_scene_string(world, value.material)
	world.sphere_renderers[entity] = owned
	return true}
get_model_renderer :: proc(
	world: ^World,
	entity: Entity,
) -> (
	ModelRenderer,
	bool,
) {value, found := world.model_renderers[entity]; return value, found}
set_model_renderer :: proc(
	world: ^World,
	entity: Entity,
	value: ModelRenderer,
) -> bool {if !has_component_data(world, entity, "ModelRenderer") {return false}
	owned := clone_model_renderer_storage(value)
	owned.model = retain_scene_string(world, value.model)
	owned.material = retain_scene_string(world, value.material)
	for slot, path in owned.materials {
		owned.materials[slot] = retain_scene_string(world, path)
	}
	destroy_model_renderer_storage(world.model_renderers[entity])
	world.model_renderers[entity] = owned
	return true}
get_ambient_light :: proc(world: ^World, entity: Entity) -> (AmbientLight, bool) {value, found :=
		world.ambient_lights[entity]
	return value, found}
set_ambient_light :: proc(
	world: ^World,
	entity: Entity,
	value: AmbientLight,
) -> bool {if !has_component_data(world, entity, "AmbientLight") {return false}
	world.ambient_lights[entity] = value
	return true}
get_directional_light :: proc(
	world: ^World,
	entity: Entity,
) -> (
	DirectionalLight,
	bool,
) {value, found := world.directional_lights[entity]; return value, found}
set_directional_light :: proc(
	world: ^World,
	entity: Entity,
	value: DirectionalLight,
) -> bool {if !has_component_data(world, entity, "DirectionalLight") {return false}
	world.directional_lights[entity] = value
	return true}
get_point_light :: proc(world: ^World, entity: Entity) -> (PointLight, bool) {value, found :=
		world.point_lights[entity]
	return value, found}
set_point_light :: proc(
	world: ^World,
	entity: Entity,
	value: PointLight,
) -> bool {if !has_component_data(world, entity, "PointLight") {return false}; world.point_lights[entity] =
		value
	return true}
get_spot_light :: proc(world: ^World, entity: Entity) -> (SpotLight, bool) {value, found :=
		world.spot_lights[entity]
	return value, found}
set_spot_light :: proc(
	world: ^World,
	entity: Entity,
	value: SpotLight,
) -> bool {if !has_component_data(world, entity, "SpotLight") {return false}; world.spot_lights[entity] =
		value
	return true}
get_tilemap_renderer :: proc(
	world: ^World,
	entity: Entity,
) -> (
	TilemapRenderer,
	bool,
) {value, found := world.tilemap_renderers[entity]; return value, found}
set_tilemap_renderer :: proc(
	world: ^World,
	entity: Entity,
	value: TilemapRenderer,
) -> bool {if !has_component_data(world, entity, "TilemapRenderer") {return false}
	owned := clone_tilemap_renderer_storage(value)
	owned.texture = retain_scene_string(world, value.texture)
	destroy_tilemap_renderer_storage(world.tilemap_renderers[entity])
	world.tilemap_renderers[entity] = owned
	return true}
get_text_renderer :: proc(world: ^World, entity: Entity) -> (TextRenderer, bool) {value, found :=
		world.text_renderers[entity]
	return value, found}
set_text_renderer :: proc(
	world: ^World,
	entity: Entity,
	value: TextRenderer,
) -> bool {if !has_component_data(world, entity, "TextRenderer") {return false}
	owned := value
	owned.text = retain_scene_string(world, value.text)
	owned.font = retain_scene_string(world, value.font)
	world.text_renderers[entity] = owned
	return true}
get_tilemap_collider :: proc(
	world: ^World,
	entity: Entity,
) -> (
	TilemapCollider,
	bool,
) {value, found := world.tilemap_colliders[entity]; return value, found}
set_tilemap_collider :: proc(
	world: ^World,
	entity: Entity,
	value: TilemapCollider,
) -> bool {if !has_component_data(world, entity, "TilemapCollider") {return false}
	owned := clone_tilemap_collider_storage(value)
	destroy_tilemap_collider_storage(world.tilemap_colliders[entity])
	world.tilemap_colliders[entity] = owned
	return true}
get_top_down_controller :: proc(
	world: ^World,
	entity: Entity,
) -> (
	TopDownController,
	bool,
) {value, found := world.top_down_controllers[entity]; return value, found}
set_top_down_controller :: proc(
	world: ^World,
	entity: Entity,
	value: TopDownController,
) -> bool {if !has_component_data(world, entity, "TopDownController") {return false}
	world.top_down_controllers[entity] = value
	return true}
get_rigid_body_2d :: proc(world: ^World, entity: Entity) -> (RigidBody2D, bool) {value, found :=
		world.rigid_bodies_2d[entity]
	return value, found}
set_rigid_body_2d :: proc(
	world: ^World,
	entity: Entity,
	value: RigidBody2D,
) -> bool {if !has_component_data(world, entity, "RigidBody2D") {return false}
	owned := value
	owned.body_type = retain_scene_string(world, value.body_type)
	world.rigid_bodies_2d[entity] = owned
	return true}
get_box_collider_2d :: proc(
	world: ^World,
	entity: Entity,
) -> (
	BoxCollider2D,
	bool,
) {value, found := world.box_colliders_2d[entity]; return value, found}
get_circle_collider_2d :: proc(
	world: ^World,
	entity: Entity,
) -> (
	CircleCollider2D,
	bool,
) {value, found := world.circle_colliders_2d[entity]; return value, found}
get_rigid_body_3d :: proc(world: ^World, entity: Entity) -> (RigidBody3D, bool) {value, found :=
		world.rigid_bodies_3d[entity]
	return value, found}
set_rigid_body_3d :: proc(
	world: ^World,
	entity: Entity,
	value: RigidBody3D,
) -> bool {if !has_component_data(world, entity, "RigidBody3D") {return false}
	owned := value
	owned.body_type = retain_scene_string(world, value.body_type)
	world.rigid_bodies_3d[entity] = owned
	return true}
get_box_collider :: proc(world: ^World, entity: Entity) -> (BoxCollider, bool) {value, found :=
		world.box_colliders[entity]
	return value, found}
set_box_collider :: proc(
	world: ^World,
	entity: Entity,
	value: BoxCollider,
) -> bool {if !has_component_data(world, entity, "BoxCollider") {return false}
	world.box_colliders[entity] = value
	return true}
get_sphere_collider :: proc(
	world: ^World,
	entity: Entity,
) -> (
	SphereCollider,
	bool,
) {value, found := world.sphere_colliders[entity]; return value, found}
set_sphere_collider :: proc(
	world: ^World,
	entity: Entity,
	value: SphereCollider,
) -> bool {if !has_component_data(world, entity, "SphereCollider") {return false}
	world.sphere_colliders[entity] = value
	return true}
get_character_controller :: proc(
	world: ^World,
	entity: Entity,
) -> (
	CharacterController,
	bool,
) {value, found := world.character_controllers[entity]; return value, found}
set_character_controller :: proc(
	world: ^World,
	entity: Entity,
	value: CharacterController,
) -> bool {if !has_component_data(world, entity, "CharacterController") {return false}
	world.character_controllers[entity] = value
	return true}
get_orbit :: proc(world: ^World, entity: Entity) -> (Orbit, bool) {value, found :=
		world.orbits[entity]
	return value, found}
set_orbit :: proc(world: ^World, entity: Entity, value: Orbit) -> bool {if !has_component_data(
		world,
		entity,
		"Orbit",
	) {return false}
	world.orbits[entity] = value
	return true}
get_rotator :: proc(world: ^World, entity: Entity) -> (Rotator, bool) {value, found :=
		world.rotators[entity]
	return value, found}
set_rotator :: proc(
	world: ^World,
	entity: Entity,
	value: Rotator,
) -> bool {if !has_component_data(world, entity, "Rotator") {return false}; world.rotators[entity] =
		value
	return true}
get_camera_2d :: proc(world: ^World, entity: Entity) -> (Camera2D, bool) {value, found :=
		world.cameras_2d[entity]
	return value, found}
set_camera_2d :: proc(
	world: ^World,
	entity: Entity,
	value: Camera2D,
) -> bool {if !has_component_data(world, entity, "Camera2D") {return false}; world.cameras_2d[entity] =
		value
	return true}
get_camera_3d :: proc(world: ^World, entity: Entity) -> (Camera3D, bool) {value, found :=
		world.cameras_3d[entity]
	return value, found}
set_camera_3d :: proc(
	world: ^World,
	entity: Entity,
	value: Camera3D,
) -> bool {if !has_component_data(world, entity, "Camera3D") {return false}; world.cameras_3d[entity] =
		value
	return true}
get_orbit_camera_3d :: proc(
	world: ^World,
	entity: Entity,
) -> (
	OrbitCamera3D,
	bool,
) {value, found := world.orbit_cameras_3d[entity]; return value, found}
set_orbit_camera_3d :: proc(
	world: ^World,
	entity: Entity,
	value: OrbitCamera3D,
) -> bool {if !has_component_data(world, entity, "OrbitCamera3D") {return false}
	owned := value
	owned.manual_action = retain_scene_string(world, value.manual_action)
	owned.yaw_axis = retain_scene_string(world, value.yaw_axis)
	owned.pitch_axis = retain_scene_string(world, value.pitch_axis)
	owned.zoom_axis = retain_scene_string(world, value.zoom_axis)
	world.orbit_cameras_3d[entity] = owned
	return true}
get_audio_listener :: proc(
	world: ^World,
	entity: Entity,
) -> (
	AudioListener,
	bool,
) {value, found := world.audio_listeners[entity]; return value, found}
set_audio_listener :: proc(
	world: ^World,
	entity: Entity,
	value: AudioListener,
) -> bool {if !has_component_data(world, entity, "AudioListener") {return false}
	world.audio_listeners[entity] = value
	return true}
get_audio_player :: proc(
	world: ^World,
	entity: Entity,
	instance_name: string,
) -> (
	AudioPlayer,
	bool,
) {
	value, found := world.audio_players[Component_Instance{entity = entity, name = instance_name}]
	return value, found
}
set_audio_player :: proc(
	world: ^World,
	entity: Entity,
	instance_name: string,
	value: AudioPlayer,
) -> bool {
	key := Component_Instance {
		entity = entity,
		name   = instance_name,
	}
	if _, found := world.audio_players[key]; !found {return false}
	key.name = retain_scene_string(world, instance_name)
	owned := value
	owned.sound = retain_scene_string(world, value.sound)
	world.audio_players[key] = owned
	return true
}
get_nav_grid_2d :: proc(world: ^World, entity: Entity) -> (NavGrid2D, bool) {value, found :=
		world.nav_grids_2d[entity]
	return value, found}
set_nav_grid_2d :: proc(
	world: ^World,
	entity: Entity,
	value: NavGrid2D,
) -> bool {if !has_component_data(world, entity, "NavGrid2D") {return false}; world.nav_grids_2d[entity] =
		value
	return true}
get_nav_agent_2d :: proc(world: ^World, entity: Entity) -> (NavAgent2D, bool) {value, found :=
		world.nav_agents_2d[entity]
	return value, found}
set_nav_agent_2d :: proc(
	world: ^World,
	entity: Entity,
	value: NavAgent2D,
) -> bool {if !has_component_data(world, entity, "NavAgent2D") {return false}; world.nav_agents_2d[entity] =
		value
	return true}

active_camera_2d :: proc(world: ^World) -> (Entity, Camera2D, bool) {
	for entity, camera in world.cameras_2d {
		if camera.active {return entity, camera, true}
	}
	return Entity(0), {}, false
}

active_camera_3d :: proc(world: ^World) -> (Entity, Camera3D, bool) {
	for entity, camera in world.cameras_3d {
		if camera.active {return entity, camera, true}
	}
	return Entity(0), {}, false
}

set_active_camera_2d :: proc(world: ^World, entity: Entity) -> bool {
	if _, found := world.cameras_2d[entity]; !found {return false}
	for candidate, &camera in world.cameras_2d {
		camera.active = candidate == entity
		world.cameras_2d[candidate] = camera
	}
	return true
}

set_active_camera_3d :: proc(world: ^World, entity: Entity) -> bool {
	if _, found := world.cameras_3d[entity]; !found {return false}
	for candidate, &camera in world.cameras_3d {
		camera.active = candidate == entity
		world.cameras_3d[candidate] = camera
	}
	return true
}

// active_audio_listener returns the selected listener only when the World has
// exactly one active listener. A false result therefore means either no
// listener is active or the scene configuration is ambiguous.
active_audio_listener :: proc(world: ^World) -> (Entity, AudioListener, bool) {
	selected_entity: Entity
	selected_listener: AudioListener
	found := false
	for entity, listener in world.audio_listeners {
		if !listener.active {continue}
		if found {return Entity(0), {}, false}
		selected_entity = entity
		selected_listener = listener
		found = true
	}
	return selected_entity, selected_listener, found
}

set_active_audio_listener :: proc(world: ^World, entity: Entity) -> bool {
	if _, found := world.audio_listeners[entity]; !found {return false}
	for candidate, &listener in world.audio_listeners {
		listener.active = candidate == entity
		world.audio_listeners[candidate] = listener
	}
	return true
}
