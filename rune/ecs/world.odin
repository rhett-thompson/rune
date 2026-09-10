package ecs

import "core:encoding/json"
import "core:mem"
import "rune:particles"
import b2 "vendor:box2d"
import b3 "vendor:box3d"

// Entity is a compact runtime handle. The low 32 bits identify an entity
// within a World and the high 32 bits identify the World generation. This
// prevents a handle cached before scene hot reload from aliasing an entity in
// the replacement World.
Entity :: distinct u64

Entity_Ref :: struct {
	id: string,
}

Component_Instance :: struct {
	entity: Entity,
	name:   string,
}

Component_Change_Kind :: enum {
	Added,
	Changed,
	Removed,
}

Component_Change_Key :: struct {
	entity: Entity,
	name:   string,
}

Component_Change :: struct {
	entity:  Entity,
	kind:    Component_Change_Kind,
	version: u64,
}

next_world_generation: u32 = 1

// Default is the only universally named layer. Projects may define additional
// names for bits 1 through 63 in project.json.
Default_Layer: u8 : 0
Default_Layer_Mask: u64 : u64(1) << Default_Layer

World :: struct {
	navigation_3d: Navigation_Runtime_3D,
	character_controllers_3d: map[Entity]CharacterController3D,
	character_controller_states_3d: map[Entity]Character_Controller_State_3D,
	character_controllers_2d: map[Entity]CharacterController2D,
	character_controller_states_2d: map[Entity]Character_Controller_State_2D,
	polygon_colliders_2d: map[Entity]PolygonCollider2D,
	segment_colliders_2d: map[Entity]SegmentCollider2D,
	capsule_colliders_2d: map[Entity]CapsuleCollider2D,
	disabled_entities: map[Entity]bool,
	lifetime_elapsed: map[Entity]f32,
	lifetimes: map[Entity]Lifetime,
	shape_renderers_2d: map[Entity]ShapeRenderer2D,
	particle_emitters_2d: map[Entity]ParticleEmitter2D,
	particle_states_2d: map[Entity]particles.State,
	model_animators: map[Entity]ModelAnimator,
	model_animation_states: map[Entity]Model_Animation_State,
	physics_2d, physics_3d: Physics_State,
	generation:                  u32,
	next_entity:                 u32,
	entity_count:                int,
	entities:                    map[Entity]bool,
	entity_ids:                  map[Entity]string,
	entities_by_id:              map[string]Entity,
	entity_names:                map[Entity]string,
	entity_tags:                 map[Entity]string,
	layer_masks:                 map[Entity]u64,
	parents:                     map[Entity]Entity,
	// Hierarchy indexes are rebuilt only when parenting changes. Rendering can
	// then walk direct child lists instead of repeatedly scanning every parent.
	roots:                       [dynamic]Entity,
	children_by_parent:          map[Entity][dynamic]Entity,
	hierarchy_dirty:             bool,
	scene_json:                  json.Value,
	component_data:              map[string]map[Entity]json.Value,
	component_instance_data:     map[string]map[Component_Instance]json.Value,
	typed_component_data:        map[string]map[Entity]any,
	// A nil arena denotes a compact allocation for a value with no references.
	typed_value_arenas:          map[rawptr]^mem.Dynamic_Arena,
	component_descriptors: map[string]Component_Descriptor,
	component_names_by_type:     map[typeid]string,
	component_change_version:    u64,
	component_changes:           map[Component_Change_Key]Component_Change,
	resources:                   map[typeid]any,
	typed_component_arena:       ^mem.Dynamic_Arena,
	scene_data_arena:            ^mem.Dynamic_Arena,
	scene_strings:               map[string]string,
	transforms:                  map[Entity]Transform,
	sprite_renderers:            map[Entity]SpriteRenderer,
	sprite_animators:            map[Entity]SpriteAnimator,
	sprite_animation_states:     map[Entity]Sprite_Animation_State,
	mesh_renderers:              map[Entity]MeshRenderer,
	sphere_renderers:            map[Entity]SphereRenderer,
	model_renderers:             map[Entity]ModelRenderer,
	skyboxes: map[Entity]Skybox,
	terrains: map[Entity]Terrain,
	terrain_states: map[Entity]Terrain_Runtime,
	terrain_revision: u64,
	post_processing:            map[Entity]PostProcessing,
	ambient_lights:              map[Entity]AmbientLight,
	directional_lights:          map[Entity]DirectionalLight,
	point_lights:                map[Entity]PointLight,
	spot_lights:                 map[Entity]SpotLight,
	tilemap_renderers:           map[Entity]TilemapRenderer,
	text_renderers:              map[Entity]TextRenderer,
	tilemap_colliders:           map[Entity]TilemapCollider,
	top_down_controllers:        map[Entity]TopDownController,
	rigid_bodies_2d:             map[Entity]RigidBody2D,
	box_colliders_2d:            map[Entity]BoxCollider2D,
	circle_colliders_2d:         map[Entity]CircleCollider2D,
	physics_2d_accumulator:      f32,
	one_way_contacts_2d: map[Physics_Pair]bool,
	one_way_shapes_2d: map[u64]One_Way_Shape_2D,
	box2d_world:                 b2.WorldId,
	box2d_bodies:                map[Entity]b2.BodyId,
	rigid_bodies_3d:             map[Entity]RigidBody3D,
	physics_3d_accumulator:      f32,
	box3d_world:                 b3.WorldId,
	box3d_bodies:                map[Entity]b3.BodyId,
	box_colliders:               map[Entity]BoxCollider,
	sphere_colliders:            map[Entity]SphereCollider,
	character_controllers:       map[Entity]CharacterController,
	orbits:                      map[Entity]Orbit,
	rotators:                    map[Entity]Rotator,
	cameras_2d:                  map[Entity]Camera2D,
	camera_follows_2d:           map[Entity]CameraFollow2D,
	cameras_3d:                  map[Entity]Camera3D,
	orbit_cameras_3d:            map[Entity]OrbitCamera3D,
	audio_listeners:             map[Entity]AudioListener,
	audio_players:               map[Component_Instance]AudioPlayer,
	nav_grids_2d:                map[Entity]NavGrid2D,
	nav_agents_2d:               map[Entity]NavAgent2D,
}

init :: proc() -> World {
	generation := next_world_generation
	next_world_generation += 1
	if next_world_generation == 0 {
		next_world_generation = 1
	}
	typed_component_arena, _ := mem.new(mem.Dynamic_Arena)
	assert(typed_component_arena != nil)
	mem.dynamic_arena_init(typed_component_arena)
	scene_data_arena, _ := mem.new(mem.Dynamic_Arena)
	assert(scene_data_arena != nil)
	mem.dynamic_arena_init(scene_data_arena)
	return World {
		character_controllers_3d = make(map[Entity]CharacterController3D),
		character_controller_states_3d = make(map[Entity]Character_Controller_State_3D),
		character_controllers_2d = make(map[Entity]CharacterController2D),
		character_controller_states_2d = make(map[Entity]Character_Controller_State_2D),
		polygon_colliders_2d = make(map[Entity]PolygonCollider2D),
		segment_colliders_2d = make(map[Entity]SegmentCollider2D),
		capsule_colliders_2d = make(map[Entity]CapsuleCollider2D),
		disabled_entities = make(map[Entity]bool),
		lifetime_elapsed = make(map[Entity]f32),
		lifetimes = make(map[Entity]Lifetime),
		shape_renderers_2d = make(map[Entity]ShapeRenderer2D),
		particle_emitters_2d = make(map[Entity]ParticleEmitter2D),
		particle_states_2d = make(map[Entity]particles.State),
		generation = generation,
		next_entity = 1,
		entities = make(map[Entity]bool),
		entity_ids = make(map[Entity]string),
		entities_by_id = make(map[string]Entity),
		entity_names = make(map[Entity]string),
		entity_tags = make(map[Entity]string),
		layer_masks = make(map[Entity]u64),
		parents = make(map[Entity]Entity),
		roots = make([dynamic]Entity),
		children_by_parent = make(map[Entity][dynamic]Entity),
		hierarchy_dirty = true,
		component_data = make(map[string]map[Entity]json.Value),
		component_instance_data = make(map[string]map[Component_Instance]json.Value),
		typed_component_data = make(map[string]map[Entity]any),
		typed_value_arenas = make(map[rawptr]^mem.Dynamic_Arena),
		component_descriptors = make(map[string]Component_Descriptor),
		component_names_by_type = make(map[typeid]string),
		component_changes = make(map[Component_Change_Key]Component_Change),
		resources = make(map[typeid]any),
		typed_component_arena = typed_component_arena,
		scene_data_arena = scene_data_arena,
		scene_strings = make(map[string]string),
		transforms = make(map[Entity]Transform),
		sprite_renderers = make(map[Entity]SpriteRenderer),
		model_animators = make(map[Entity]ModelAnimator),
		model_animation_states = make(map[Entity]Model_Animation_State),
		sprite_animators = make(map[Entity]SpriteAnimator),
		sprite_animation_states = make(map[Entity]Sprite_Animation_State),
		mesh_renderers = make(map[Entity]MeshRenderer),
		sphere_renderers = make(map[Entity]SphereRenderer),
		model_renderers = make(map[Entity]ModelRenderer),
		skyboxes = make(map[Entity]Skybox),
		terrains = make(map[Entity]Terrain),
		terrain_states = make(map[Entity]Terrain_Runtime),
		post_processing = make(map[Entity]PostProcessing),
		ambient_lights = make(map[Entity]AmbientLight),
		directional_lights = make(map[Entity]DirectionalLight),
		point_lights = make(map[Entity]PointLight),
		spot_lights = make(map[Entity]SpotLight),
		tilemap_renderers = make(map[Entity]TilemapRenderer),
		text_renderers = make(map[Entity]TextRenderer),
		tilemap_colliders = make(map[Entity]TilemapCollider),
		top_down_controllers = make(map[Entity]TopDownController),
		rigid_bodies_2d = make(map[Entity]RigidBody2D),
		box_colliders_2d = make(map[Entity]BoxCollider2D),
		circle_colliders_2d = make(map[Entity]CircleCollider2D),
		physics_2d = physics_state_init(),
		physics_3d = physics_state_init(),
		box2d_bodies = make(map[Entity]b2.BodyId),
		one_way_shapes_2d = make(map[u64]One_Way_Shape_2D),
		one_way_contacts_2d = make(map[Physics_Pair]bool),
		rigid_bodies_3d = make(map[Entity]RigidBody3D),
		box3d_bodies = make(map[Entity]b3.BodyId),
		box_colliders = make(map[Entity]BoxCollider),
		sphere_colliders = make(map[Entity]SphereCollider),
		character_controllers = make(map[Entity]CharacterController),
		orbits = make(map[Entity]Orbit),
		rotators = make(map[Entity]Rotator),
		cameras_2d = make(map[Entity]Camera2D),
		camera_follows_2d = make(map[Entity]CameraFollow2D),
		cameras_3d = make(map[Entity]Camera3D),
		orbit_cameras_3d = make(map[Entity]OrbitCamera3D),
		audio_listeners = make(map[Entity]AudioListener),
		audio_players = make(map[Component_Instance]AudioPlayer),
		nav_grids_2d = make(map[Entity]NavGrid2D),
		nav_agents_2d = make(map[Entity]NavAgent2D),
	}
}

// destroy releases all World-owned containers and native state. It is safe to
// call more than once, which keeps scene replacement and shutdown ownership
// straightforward.
destroy :: proc(world: ^World) {
	if world == nil {return}
	destroy_navigation_3d(world)
	for _, &state in world.particle_states_2d {particles.destroy(&state)}
	delete(world.particle_states_2d)
	delete(world.particle_emitters_2d)
	physics_2d_shutdown(world)
	physics_3d_shutdown(world)
	destroy_terrains(world)
	for _, components in world.component_data {delete(components)}
	for _, instances in world.component_instance_data {delete(instances)}
	for _, components in world.typed_component_data {delete(components)}
	for data, arena in world.typed_value_arenas {
		if arena != nil {destroy_typed_value_arena(arena)} else {mem.free(data)}
	}
	delete(world.typed_value_arenas)
	for _, children in world.children_by_parent {delete(children)}
	for _, renderer in world.model_renderers {destroy_model_renderer_storage(renderer)}
	for _, renderer in world.tilemap_renderers {destroy_tilemap_renderer_storage(renderer)}
	for _, collider in world.tilemap_colliders {destroy_tilemap_collider_storage(collider)}
	delete(world.roots)
	delete(world.shape_renderers_2d)
	delete(world.lifetimes)
	delete(world.disabled_entities)
	delete(world.lifetime_elapsed)
	delete(world.entities)
	delete(world.entity_ids)
	delete(world.entities_by_id)
	delete(world.entity_names)
	delete(world.entity_tags)
	delete(world.layer_masks)
	delete(world.parents)
	delete(world.children_by_parent)
	delete(world.component_data)
	delete(world.component_instance_data)
	delete(world.typed_component_data)
	delete(world.component_descriptors)
	delete(world.component_names_by_type)
	delete(world.component_changes)
	delete(world.resources)
	delete(world.scene_strings)
	delete(world.transforms)
	delete(world.sprite_renderers)
	delete(world.model_animators)
	delete(world.model_animation_states)
	delete(world.sprite_animators)
	delete(world.sprite_animation_states)
	delete(world.mesh_renderers)
	delete(world.sphere_renderers)
	delete(world.model_renderers)
	delete(world.skyboxes)
	delete(world.post_processing)
	delete(world.ambient_lights)
	delete(world.directional_lights)
	delete(world.point_lights)
	delete(world.spot_lights)
	delete(world.tilemap_renderers)
	delete(world.text_renderers)
	delete(world.tilemap_colliders)
	delete(world.top_down_controllers)
	delete(world.rigid_bodies_2d)
	delete(world.box_colliders_2d)
	for _, collider in world.polygon_colliders_2d {delete(collider.vertices)}
	delete(world.polygon_colliders_2d)
	delete(world.segment_colliders_2d)
	delete(world.capsule_colliders_2d)
	delete(world.circle_colliders_2d)
	physics_state_destroy(&world.physics_2d)
	physics_state_destroy(&world.physics_3d)
	delete(world.box2d_bodies)
	delete(world.one_way_shapes_2d)
	delete(world.one_way_contacts_2d)
	delete(world.rigid_bodies_3d)
	delete(world.box3d_bodies)
	delete(world.box_colliders)
	delete(world.sphere_colliders)
	delete(world.character_controllers_3d)
	delete(world.character_controller_states_3d)
	delete(world.character_controllers_2d)
	delete(world.character_controller_states_2d)
	delete(world.character_controllers)
	delete(world.orbits)
	delete(world.rotators)
	delete(world.cameras_2d)
	delete(world.camera_follows_2d)
	delete(world.cameras_3d)
	delete(world.orbit_cameras_3d)
	delete(world.audio_listeners)
	delete(world.audio_players)
	delete(world.nav_grids_2d)
	delete(world.nav_agents_2d)
	world.typed_component_data = nil
	world.component_descriptors = nil
	world.component_names_by_type = nil
	world.component_changes = nil
	world.resources = nil
	if world.typed_component_arena != nil {
		mem.dynamic_arena_destroy(world.typed_component_arena)
		mem.free(world.typed_component_arena)
		world.typed_component_arena = nil
	}
	if world.scene_data_arena != nil {
		mem.dynamic_arena_destroy(world.scene_data_arena)
		mem.free(world.scene_data_arena)
		world.scene_data_arena = nil
	}
	world^ = {}
}

// add_component attaches JSON data to an entity. Components must be explicitly
// registered so misspelled or unsupported component names fail at load time.
add_component :: proc(
	world: ^World,
	registry: ^Component_Registry,
	entity: Entity,
	name: string,
	data: json.Value,
) -> bool {
	if !is_alive(world, entity) || !has_component(registry, name) {return false}
	return add_component_owned(
		world,
		registry,
		entity,
		retain_scene_string(world, name),
		json.clone_value(data, scene_data_allocator(world)),
	)
}

add_component_owned :: proc(
	world: ^World,
	registry: ^Component_Registry,
	entity: Entity,
	name: string,
	data: json.Value,
) -> bool {
	if !is_alive(world, entity) || !has_component(registry, name) {
		return false
	}
	descriptor, _ := component_descriptor(registry, name)
	// Terrain owns a static body; mixing another 3D body/controller on the same
	// entity would give two systems ownership of that body and its transform.
	for other in ([]string{"RigidBody3D","BoxCollider","SphereCollider","CharacterController","CharacterController3D"}) {
		if (name == "Terrain" && has_component_data(world,entity,other)) ||
		   (name == other && has_component_data(world,entity,"Terrain")) {return false}
	}
	already_present := has_component_data(world, entity, name)
	if descriptor.type_id != nil {world.component_names_by_type[descriptor.type_id] = name}
	if descriptor.create_typed != nil {
		if descriptor.allow_multiple || world.typed_component_arena == nil {return false}
		arena := new_typed_value_arena()
		if arena == nil {return false}
		allocator := mem.dynamic_arena_allocator(arena)
		typed_value, created := descriptor.create_typed(data, descriptor.default_value, allocator)
		if !created {
			destroy_typed_value_arena(arena)
			return false
		}
		if descriptor.copy_value {
			info := type_info_of(descriptor.type_id)
			storage, err := mem.alloc(max(1, info.size), info.align)
			if err != nil {
				destroy_typed_value_arena(arena)
				return false
			}
			mem.copy(storage, typed_value.data, info.size)
			typed_value.data = storage
			destroy_typed_value_arena(arena)
			arena = nil
		}

		components, components_found := world.component_data[name]
		if !components_found {components = make(map[Entity]json.Value)}
		components[entity] = data
		world.component_data[name] = components

		typed_components, typed_found := world.typed_component_data[name]
		if !typed_found {typed_components = make(map[Entity]any)}
		release_typed_value(world, typed_components[entity])
		world.typed_value_arenas[typed_value.data] = arena
		typed_components[entity] = typed_value
		world.typed_component_data[name] = typed_components
		world.component_descriptors[name] = descriptor
		record_component_change(world, entity, name, .Changed if already_present else .Added)
		return true
	}
	if descriptor.allow_multiple {
		instances, ok := data.(json.Object)
		if !ok || len(instances) == 0 {return false}

		parsed_audio := make(map[Component_Instance]AudioPlayer, context.temp_allocator)
		for instance_name, instance_data in instances {
			if len(instance_name) == 0 {return false}
			key := Component_Instance {
				entity = entity,
				name   = instance_name,
			}
			if name == "AudioPlayer" {
				value, parsed := audio_player_from_json(instance_data)
				if !parsed {return false}
				parsed_audio[key] = value
			}
		}
		if already_present {
			if old_values, found := world.component_instance_data[name]; found {
				for key in old_values {
					if key.entity == entity {delete_key(&old_values, key)}
				}
				world.component_instance_data[name] = old_values
			}
			if name == "AudioPlayer" {
				for key in world.audio_players {
					if key.entity == entity {delete_key(&world.audio_players, key)}
				}
			}
		}

		values, values_found := world.component_instance_data[name]
		if !values_found {values = make(map[Component_Instance]json.Value)}
		for instance_name, instance_data in instances {
			key := Component_Instance {
				entity = entity,
				name   = instance_name,
			}
			values[key] = instance_data
			if name == "AudioPlayer" {world.audio_players[key] = retain_audio_player(world, parsed_audio[key])}
		}
		world.component_instance_data[name] = values
		components, components_found := world.component_data[name]
		if !components_found {components = make(map[Entity]json.Value)}
		components[entity] = data
		world.component_data[name] = components
		world.component_descriptors[name] = descriptor
		record_component_change(world, entity, name, .Changed if already_present else .Added)
		return true
	}

	shape_renderer_2d: ShapeRenderer2D
	lifetime: Lifetime
	transform: Transform
	sprite_renderer: SpriteRenderer
	model_animator: ModelAnimator
	particle_emitter_2d: ParticleEmitter2D
	sprite_animator: SpriteAnimator
	mesh_renderer: MeshRenderer
	sphere_renderer: SphereRenderer
	model_renderer: ModelRenderer
	terrain_value: Terrain
	skybox: Skybox
	post_processing: PostProcessing
	ambient_light: AmbientLight
	directional_light: DirectionalLight
	point_light: PointLight
	spot_light: SpotLight
	tilemap_renderer: TilemapRenderer
	text_renderer: TextRenderer
	tilemap_collider: TilemapCollider
	top_down_controller: TopDownController
	rigid_body_2d: RigidBody2D
	box_collider_2d: BoxCollider2D
	polygon_collider_2d: PolygonCollider2D
	segment_collider_2d: SegmentCollider2D
	character_controller_3d: CharacterController3D
	character_controller_2d: CharacterController2D
	capsule_collider_2d: CapsuleCollider2D
	circle_collider_2d: CircleCollider2D
	rigid_body_3d: RigidBody3D
	box_collider: BoxCollider
	sphere_collider: SphereCollider
	character_controller: CharacterController
	orbit: Orbit
	rotator: Rotator
	camera_2d: Camera2D
	camera_follow_2d: CameraFollow2D
	camera_3d: Camera3D
	orbit_camera_3d: OrbitCamera3D
	audio_listener: AudioListener
	nav_grid_2d: NavGrid2D
	nav_agent_2d: NavAgent2D
	parse_ok: bool
	if name == "Terrain" {terrain_value, parse_ok = terrain_from_json(data); if !parse_ok {return false}}
	if name == "Skybox" {skybox, parse_ok = skybox_from_json(data); if !parse_ok {return false}}
	if name == "PostProcessing" {post_processing, parse_ok = post_processing_from_json(data); if !parse_ok {return false}}
	if name == "PolygonCollider2D" {polygon_collider_2d, parse_ok = polygon_collider_2d_from_json(data); if !parse_ok {return false}}
	if name == "SegmentCollider2D" {segment_collider_2d, parse_ok = segment_collider_2d_from_json(data); if !parse_ok {return false}}
	if name == "CharacterController3D" {character_controller_3d, parse_ok = character_controller_3d_from_json(data); if !parse_ok {return false}}
	if name == "CharacterController2D" {character_controller_2d, parse_ok = character_controller_2d_from_json(data); if !parse_ok {return false}}
	if name == "CapsuleCollider2D" {capsule_collider_2d, parse_ok = capsule_collider_2d_from_json(data); if !parse_ok {return false}}
	if name == "Lifetime" {
		lifetime, parse_ok = lifetime_from_json(data)
		if !parse_ok {return false}
	}
	if name == "ShapeRenderer2D" {
		shape_renderer_2d, parse_ok = shape_renderer_2d_from_json(data)
		if !parse_ok {return false}
	}
	if name == "ParticleEmitter2D" {
		particle_emitter_2d, parse_ok = particle_emitter_2d_from_json(data)
		if !parse_ok {return false}
		particle_emitter_2d.texture = retain_scene_string(world, particle_emitter_2d.texture)
	}
	if name == "Transform" {
		transform, parse_ok = transform_from_json(data)
		if !parse_ok {
			return false
		}
	}
	if name ==
	   "SpriteRenderer" {sprite_renderer, parse_ok = sprite_renderer_from_json(data); if !parse_ok {return false}}
	if name == "ModelAnimator" {
		model_animator, parse_ok = model_animator_from_json(data)
		if !parse_ok {return false}
	}
	if name ==
	   "SpriteAnimator" {sprite_animator, parse_ok = sprite_animator_from_json(data); if !parse_ok {return false}}
	if name ==
	   "MeshRenderer" {mesh_renderer, parse_ok = mesh_renderer_from_json(data); if !parse_ok {return false}}
	if name ==
	   "SphereRenderer" {sphere_renderer, parse_ok = sphere_renderer_from_json(data); if !parse_ok {return false}}
	if name ==
	   "ModelRenderer" {model_renderer, parse_ok = model_renderer_from_json(data); if !parse_ok {return false}}
	if name ==
	   "AmbientLight" {ambient_light, parse_ok = ambient_light_from_json(data); if !parse_ok {return false}}
	if name ==
	   "DirectionalLight" {directional_light, parse_ok = directional_light_from_json(data); if !parse_ok {return false}}
	if name ==
	   "PointLight" {point_light, parse_ok = point_light_from_json(data); if !parse_ok {return false}}
	if name ==
	   "SpotLight" {spot_light, parse_ok = spot_light_from_json(data); if !parse_ok {return false}}
	if name ==
	   "TilemapRenderer" {tilemap_renderer, parse_ok = tilemap_renderer_from_json(data); if !parse_ok {return false}}
	if name ==
	   "TextRenderer" {text_renderer, parse_ok = text_renderer_from_json(data); if !parse_ok {return false}}
	if name ==
	   "TilemapCollider" {tilemap_collider, parse_ok = tilemap_collider_from_json(data); if !parse_ok {return false}}
	if name ==
	   "TopDownController" {top_down_controller, parse_ok = top_down_controller_from_json(data); if !parse_ok {return false}}
	if name ==
	   "RigidBody2D" {rigid_body_2d, parse_ok = rigid_body_2d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "BoxCollider2D" {box_collider_2d, parse_ok = box_collider_2d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "CircleCollider2D" {circle_collider_2d, parse_ok = circle_collider_2d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "RigidBody3D" {rigid_body_3d, parse_ok = rigid_body_3d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "BoxCollider" {box_collider, parse_ok = box_collider_from_json(data); if !parse_ok {return false}}
	if name ==
	   "SphereCollider" {sphere_collider, parse_ok = sphere_collider_from_json(data); if !parse_ok {return false}}
	if name ==
	   "CharacterController" {character_controller, parse_ok = character_controller_from_json(data); if !parse_ok {return false}}
	if name == "Orbit" {orbit, parse_ok = orbit_from_json(data); if !parse_ok {return false}}
	if name == "Rotator" {rotator, parse_ok = rotator_from_json(data); if !parse_ok {return false}}
	if name ==
	   "Camera2D" {camera_2d, parse_ok = camera_2d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "CameraFollow2D" {camera_follow_2d, parse_ok = camera_follow_2d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "Camera3D" {camera_3d, parse_ok = camera_3d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "OrbitCamera3D" {orbit_camera_3d, parse_ok = orbit_camera_3d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "AudioListener" {audio_listener, parse_ok = audio_listener_from_json(data); if !parse_ok {return false}}
	if name ==
	   "NavGrid2D" {nav_grid_2d, parse_ok = nav_grid_2d_from_json(data); if !parse_ok {return false}}
	if name ==
	   "NavAgent2D" {nav_agent_2d, parse_ok = nav_agent_2d_from_json(data); if !parse_ok {return false}}
	if already_present {
		if name == "ModelRenderer" {
			destroy_model_renderer_storage(world.model_renderers[entity])
		}
		if name == "TilemapRenderer" {
			destroy_tilemap_renderer_storage(world.tilemap_renderers[entity])
		}
		if name == "TilemapCollider" {
			destroy_tilemap_collider_storage(world.tilemap_colliders[entity])
		}
	}

	components, component_type_found := world.component_data[name]
	if !component_type_found {
		components = make(map[Entity]json.Value)
	}
	components[entity] = data
	world.component_data[name] = components

	kind: Component_Change_Kind = .Changed if already_present else .Added
	switch name {
	case "ShapeRenderer2D":
		commit_component_value(world, entity, name, &world.shape_renderers_2d, shape_renderer_2d, kind)
	case "Lifetime":
		commit_component_value(world, entity, name, &world.lifetimes, lifetime, kind)
	case "Transform":
		commit_component_value(world, entity, name, &world.transforms, transform, kind)
	case "SpriteRenderer":
		commit_component_value(world, entity, name, &world.sprite_renderers, sprite_renderer, kind)
	case "ModelAnimator":
		commit_component_value(world, entity, name, &world.model_animators, model_animator, kind)
	case "ParticleEmitter2D":
		commit_component_value(world, entity, name, &world.particle_emitters_2d, particle_emitter_2d, kind)
	case "SpriteAnimator":
		commit_component_value(world, entity, name, &world.sprite_animators, sprite_animator, kind)
	case "MeshRenderer":
		commit_component_value(world, entity, name, &world.mesh_renderers, mesh_renderer, kind)
	case "SphereRenderer":
		commit_component_value(world, entity, name, &world.sphere_renderers, sphere_renderer, kind)
	case "ModelRenderer":
		commit_component_value(world, entity, name, &world.model_renderers, model_renderer, kind)
	case "AmbientLight":
		commit_component_value(world, entity, name, &world.ambient_lights, ambient_light, kind)
	case "Terrain":
		commit_component_value(world, entity, name, &world.terrains, terrain_value, kind)
	case "Skybox":
		commit_component_value(world, entity, name, &world.skyboxes, skybox, kind)
	case "PostProcessing":
		commit_component_value(world, entity, name, &world.post_processing, post_processing, kind)
	case "DirectionalLight":
		commit_component_value(world, entity, name, &world.directional_lights, directional_light, kind)
	case "PointLight":
		commit_component_value(world, entity, name, &world.point_lights, point_light, kind)
	case "SpotLight":
		commit_component_value(world, entity, name, &world.spot_lights, spot_light, kind)
	case "TilemapRenderer":
		commit_component_value(world, entity, name, &world.tilemap_renderers, tilemap_renderer, kind)
	case "TextRenderer":
		commit_component_value(world, entity, name, &world.text_renderers, text_renderer, kind)
	case "TilemapCollider":
		commit_component_value(world, entity, name, &world.tilemap_colliders, tilemap_collider, kind)
	case "TopDownController":
		commit_component_value(world, entity, name, &world.top_down_controllers, top_down_controller, kind)
	case "RigidBody2D":
		commit_component_value(world, entity, name, &world.rigid_bodies_2d, preserve_simulation_state(world, entity, rigid_body_2d), kind)
	case "BoxCollider2D":
		commit_component_value(world, entity, name, &world.box_colliders_2d, box_collider_2d, kind)
	case "PolygonCollider2D":
		commit_component_value(world, entity, name, &world.polygon_colliders_2d, polygon_collider_2d, kind)
	case "SegmentCollider2D":
		commit_component_value(world, entity, name, &world.segment_colliders_2d, segment_collider_2d, kind)
	case "CharacterController3D":
		commit_component_value(world, entity, name, &world.character_controllers_3d, character_controller_3d, kind)
	case "CharacterController2D":
		commit_component_value(world, entity, name, &world.character_controllers_2d, character_controller_2d, kind)
	case "CapsuleCollider2D":
		commit_component_value(world, entity, name, &world.capsule_colliders_2d, capsule_collider_2d, kind)
	case "CircleCollider2D":
		commit_component_value(world, entity, name, &world.circle_colliders_2d, circle_collider_2d, kind)
	case "RigidBody3D":
		commit_component_value(world, entity, name, &world.rigid_bodies_3d, rigid_body_3d, kind)
	case "BoxCollider":
		commit_component_value(world, entity, name, &world.box_colliders, box_collider, kind)
	case "SphereCollider":
		commit_component_value(world, entity, name, &world.sphere_colliders, sphere_collider, kind)
	case "CharacterController":
		commit_component_value(world, entity, name, &world.character_controllers, preserve_simulation_state(world, entity, character_controller), kind)
	case "Orbit":
		commit_component_value(world, entity, name, &world.orbits, orbit, kind)
	case "Rotator":
		commit_component_value(world, entity, name, &world.rotators, rotator, kind)
	case "Camera2D":
		commit_component_value(world, entity, name, &world.cameras_2d, camera_2d, kind)
	case "CameraFollow2D":
		commit_component_value(world, entity, name, &world.camera_follows_2d, camera_follow_2d, kind)
	case "Camera3D":
		commit_component_value(world, entity, name, &world.cameras_3d, camera_3d, kind)
	case "OrbitCamera3D":
		commit_component_value(world, entity, name, &world.orbit_cameras_3d, orbit_camera_3d, kind)
	case "AudioListener":
		commit_component_value(world, entity, name, &world.audio_listeners, audio_listener, kind)
	case "NavGrid2D":
		commit_component_value(world, entity, name, &world.nav_grids_2d, nav_grid_2d, kind)
	case "NavAgent2D":
		commit_component_value(world, entity, name, &world.nav_agents_2d, nav_agent_2d, kind)
	case:
		record_component_change(world, entity, name, kind)
	}
	world.component_descriptors[name] = descriptor
	return true
}
// add_typed_component attaches a runtime-created custom component without
// requiring game code to convert the struct through json.Value. Rune retains a
// JSON snapshot internally so membership queries and scene-shape operations use
// the same path as scene-authored components.
add_typed_component :: proc(
	world: ^World,
	registry: ^Component_Registry,
	entity: Entity,
	name: string,
	value: $T,
) -> bool {
	descriptor, found := component_descriptor(registry, name)
	if !found || descriptor.create_typed == nil || descriptor.type_id != typeid_of(T) {
		return false
	}
	bytes, marshal_error := json.marshal(value)
	if marshal_error != nil {return false}
	defer delete(bytes)
	data: json.Value
	if json.unmarshal(bytes, &data) != nil {return false}
	defer json.destroy_value(data)
	return add_component(world, registry, entity, name, data)
}

remove_component :: proc(world: ^World, entity: Entity, name: string) -> bool {
	components, found := world.component_data[name]
	if !found {
		return false
	}
	_, component_found := components[entity]
	if !component_found {
		return false
	}

	name := retain_scene_string(world, name)
	if name == "NavAgent3D" {remove_navigation_agent_3d(world,entity)}
	if name == "NavMesh3D" {remove_navigation_mesh_3d(world,entity)}
	record_component_change(world, entity, name, .Removed)
	invalidate_component_physics(world, entity, name)
	delete_key(&components, entity)
	world.component_data[name] = components
	if typed_components, typed_found := world.typed_component_data[name]; typed_found {
		release_typed_value(world, typed_components[entity])
		delete_key(&typed_components, entity)
		world.typed_component_data[name] = typed_components
	}
	if name == "Transform" {
		delete_key(&world.transforms, entity)
	}
	if name == "SpriteRenderer" {delete_key(&world.sprite_renderers, entity)}
	if name == "ParticleEmitter2D" {
		remove_particle_state_2d(world, entity)
		delete_key(&world.particle_emitters_2d, entity)
	}
	if name == "ModelAnimator" {
		delete_key(&world.model_animators, entity)
		delete_key(&world.model_animation_states, entity)
	}
	if name == "SpriteAnimator" {
		delete_key(&world.sprite_animators, entity)
		delete_key(&world.sprite_animation_states, entity)
	}
	if name == "MeshRenderer" {delete_key(&world.mesh_renderers, entity)}
	if name == "SphereRenderer" {delete_key(&world.sphere_renderers, entity)}
	if name == "ModelRenderer" {
		destroy_model_renderer_storage(world.model_renderers[entity])
		delete_key(&world.model_renderers, entity)
	}
	if name == "Terrain" {remove_terrain_runtime(world,entity); delete_key(&world.terrains,entity)}
	if name == "Skybox" {delete_key(&world.skyboxes, entity)}
	if name == "PostProcessing" {delete_key(&world.post_processing, entity)}
	if name == "AmbientLight" {delete_key(&world.ambient_lights, entity)}
	if name == "DirectionalLight" {delete_key(&world.directional_lights, entity)}
	if name == "PointLight" {delete_key(&world.point_lights, entity)}
	if name == "SpotLight" {delete_key(&world.spot_lights, entity)}
	if name == "TilemapRenderer" {
		destroy_tilemap_renderer_storage(world.tilemap_renderers[entity])
		delete_key(&world.tilemap_renderers, entity)
	}
	if name == "ShapeRenderer2D" {delete_key(&world.shape_renderers_2d, entity)}
	if name == "Lifetime" {delete_key(&world.lifetimes, entity); delete_key(&world.lifetime_elapsed, entity)}
	if name == "TextRenderer" {delete_key(&world.text_renderers, entity)}
	if name == "TilemapCollider" {
		destroy_tilemap_collider_storage(world.tilemap_colliders[entity])
		delete_key(&world.tilemap_colliders, entity)
	}
	if name == "TopDownController" {delete_key(&world.top_down_controllers, entity)}
	if name == "RigidBody2D" {delete_key(&world.rigid_bodies_2d, entity)}
	if name == "BoxCollider2D" {delete_key(&world.box_colliders_2d, entity)}
	if name == "PolygonCollider2D" {delete(world.polygon_colliders_2d[entity].vertices); delete_key(&world.polygon_colliders_2d, entity)}
	if name == "SegmentCollider2D" {delete_key(&world.segment_colliders_2d, entity)}
	if name == "CharacterController3D" {delete_key(&world.character_controllers_3d, entity); delete_key(&world.character_controller_states_3d, entity)}
	if name == "CharacterController2D" {delete_key(&world.character_controllers_2d, entity); delete_key(&world.character_controller_states_2d, entity)}
	if name == "CapsuleCollider2D" {delete_key(&world.capsule_colliders_2d, entity)}
	if name == "CircleCollider2D" {delete_key(&world.circle_colliders_2d, entity)}
	if name ==
	   "RigidBody3D" {delete_key(&world.rigid_bodies_3d, entity); delete_key(&world.box3d_bodies, entity)}
	if name == "BoxCollider" {delete_key(&world.box_colliders, entity)}
	if name == "SphereCollider" {delete_key(&world.sphere_colliders, entity)}
	if name == "CharacterController" {delete_key(&world.character_controllers, entity)}
	if name == "Orbit" {delete_key(&world.orbits, entity)}
	if name == "Rotator" {delete_key(&world.rotators, entity)}
	if name == "Camera2D" {delete_key(&world.cameras_2d, entity)}
	if name == "CameraFollow2D" {delete_key(&world.camera_follows_2d, entity)}
	if name == "Camera3D" {delete_key(&world.cameras_3d, entity)}
	if name == "OrbitCamera3D" {delete_key(&world.orbit_cameras_3d, entity)}
	if name == "AudioListener" {delete_key(&world.audio_listeners, entity)}
	if name == "AudioPlayer" {
		for key in world.audio_players {
			if key.entity == entity {delete_key(&world.audio_players, key)}
		}
	}
	if instances, instances_found := world.component_instance_data[name]; instances_found {
		for key in instances {
			if key.entity == entity {delete_key(&instances, key)}
		}
		world.component_instance_data[name] = instances
	}
	if name == "NavGrid2D" {delete_key(&world.nav_grids_2d, entity)}
	if name == "NavAgent2D" {delete_key(&world.nav_agents_2d, entity)}
	return true
}
