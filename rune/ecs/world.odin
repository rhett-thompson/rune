package ecs

import "core:encoding/json"
import "core:mem"
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
	typed_component_descriptors: map[string]Component_Descriptor,
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
		typed_component_descriptors = make(map[string]Component_Descriptor),
		component_names_by_type = make(map[typeid]string),
		component_changes = make(map[Component_Change_Key]Component_Change),
		resources = make(map[typeid]any),
		typed_component_arena = typed_component_arena,
		scene_data_arena = scene_data_arena,
		scene_strings = make(map[string]string),
		transforms = make(map[Entity]Transform),
		sprite_renderers = make(map[Entity]SpriteRenderer),
		sprite_animators = make(map[Entity]SpriteAnimator),
		sprite_animation_states = make(map[Entity]Sprite_Animation_State),
		mesh_renderers = make(map[Entity]MeshRenderer),
		sphere_renderers = make(map[Entity]SphereRenderer),
		model_renderers = make(map[Entity]ModelRenderer),
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
		box2d_bodies = make(map[Entity]b2.BodyId),
		rigid_bodies_3d = make(map[Entity]RigidBody3D),
		box3d_bodies = make(map[Entity]b3.BodyId),
		box_colliders = make(map[Entity]BoxCollider),
		sphere_colliders = make(map[Entity]SphereCollider),
		character_controllers = make(map[Entity]CharacterController),
		orbits = make(map[Entity]Orbit),
		rotators = make(map[Entity]Rotator),
		cameras_2d = make(map[Entity]Camera2D),
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
	physics_2d_shutdown(world)
	physics_3d_shutdown(world)
	for _, components in world.component_data {delete(components)}
	for _, instances in world.component_instance_data {delete(instances)}
	for _, components in world.typed_component_data {delete(components)}
	for _, children in world.children_by_parent {delete(children)}
	for _, renderer in world.model_renderers {destroy_model_renderer_storage(renderer)}
	for _, renderer in world.tilemap_renderers {destroy_tilemap_renderer_storage(renderer)}
	for _, collider in world.tilemap_colliders {destroy_tilemap_collider_storage(collider)}
	delete(world.roots)
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
	delete(world.typed_component_descriptors)
	delete(world.component_names_by_type)
	delete(world.component_changes)
	delete(world.resources)
	delete(world.scene_strings)
	delete(world.transforms)
	delete(world.sprite_renderers)
	delete(world.sprite_animators)
	delete(world.sprite_animation_states)
	delete(world.mesh_renderers)
	delete(world.sphere_renderers)
	delete(world.model_renderers)
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
	delete(world.circle_colliders_2d)
	delete(world.box2d_bodies)
	delete(world.rigid_bodies_3d)
	delete(world.box3d_bodies)
	delete(world.box_colliders)
	delete(world.sphere_colliders)
	delete(world.character_controllers)
	delete(world.orbits)
	delete(world.rotators)
	delete(world.cameras_2d)
	delete(world.cameras_3d)
	delete(world.orbit_cameras_3d)
	delete(world.audio_listeners)
	delete(world.audio_players)
	delete(world.nav_grids_2d)
	delete(world.nav_agents_2d)
	world.typed_component_data = nil
	world.typed_component_descriptors = nil
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
	already_present := has_component_data(world, entity, name)
	if descriptor.type_id != nil {world.component_names_by_type[descriptor.type_id] = name}
	if descriptor.create_typed != nil {
		if descriptor.allow_multiple || world.typed_component_arena == nil {return false}
		allocator := mem.dynamic_arena_allocator(world.typed_component_arena)
		typed_value, created := descriptor.create_typed(data, descriptor.default_value, allocator)
		if !created {return false}

		components, components_found := world.component_data[name]
		if !components_found {components = make(map[Entity]json.Value)}
		components[entity] = data
		world.component_data[name] = components

		typed_components, typed_found := world.typed_component_data[name]
		if !typed_found {typed_components = make(map[Entity]any)}
		typed_components[entity] = typed_value
		world.typed_component_data[name] = typed_components
		world.typed_component_descriptors[name] = descriptor
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
			if name == "AudioPlayer" {world.audio_players[key] = parsed_audio[key]}
		}
		world.component_instance_data[name] = values
		components, components_found := world.component_data[name]
		if !components_found {components = make(map[Entity]json.Value)}
		components[entity] = data
		world.component_data[name] = components
		record_component_change(world, entity, name, .Changed if already_present else .Added)
		return true
	}

	transform: Transform
	sprite_renderer: SpriteRenderer
	sprite_animator: SpriteAnimator
	mesh_renderer: MeshRenderer
	sphere_renderer: SphereRenderer
	model_renderer: ModelRenderer
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
	circle_collider_2d: CircleCollider2D
	rigid_body_3d: RigidBody3D
	box_collider: BoxCollider
	sphere_collider: SphereCollider
	character_controller: CharacterController
	orbit: Orbit
	rotator: Rotator
	camera_2d: Camera2D
	camera_3d: Camera3D
	orbit_camera_3d: OrbitCamera3D
	audio_listener: AudioListener
	nav_grid_2d: NavGrid2D
	nav_agent_2d: NavAgent2D
	parse_ok: bool
	if name == "Transform" {
		transform, parse_ok = transform_from_json(data)
		if !parse_ok {
			return false
		}
	}
	if name ==
	   "SpriteRenderer" {sprite_renderer, parse_ok = sprite_renderer_from_json(data); if !parse_ok {return false}}
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

	if name == "Transform" {
		world.transforms[entity] = transform
	}
	if name == "SpriteRenderer" {world.sprite_renderers[entity] = sprite_renderer}
	if name == "SpriteAnimator" {
		world.sprite_animators[entity] = sprite_animator
		world.sprite_animation_states[entity] = {}
	}
	if name == "MeshRenderer" {world.mesh_renderers[entity] = mesh_renderer}
	if name == "SphereRenderer" {world.sphere_renderers[entity] = sphere_renderer}
	if name == "ModelRenderer" {world.model_renderers[entity] = model_renderer}
	if name == "AmbientLight" {world.ambient_lights[entity] = ambient_light}
	if name == "DirectionalLight" {world.directional_lights[entity] = directional_light}
	if name == "PointLight" {world.point_lights[entity] = point_light}
	if name == "SpotLight" {world.spot_lights[entity] = spot_light}
	if name == "TilemapRenderer" {world.tilemap_renderers[entity] = tilemap_renderer}
	if name == "TextRenderer" {world.text_renderers[entity] = text_renderer}
	if name == "TilemapCollider" {world.tilemap_colliders[entity] = tilemap_collider}
	if name == "TopDownController" {world.top_down_controllers[entity] = top_down_controller}
	if name == "RigidBody2D" {world.rigid_bodies_2d[entity] = rigid_body_2d}
	if name == "BoxCollider2D" {world.box_colliders_2d[entity] = box_collider_2d}
	if name == "CircleCollider2D" {world.circle_colliders_2d[entity] = circle_collider_2d}
	if name == "RigidBody3D" {world.rigid_bodies_3d[entity] = rigid_body_3d}
	if name == "BoxCollider" {world.box_colliders[entity] = box_collider}
	if name == "SphereCollider" {world.sphere_colliders[entity] = sphere_collider}
	if name == "CharacterController" {world.character_controllers[entity] = character_controller}
	if name == "Orbit" {world.orbits[entity] = orbit}
	if name == "Rotator" {world.rotators[entity] = rotator}
	if name == "Camera2D" {world.cameras_2d[entity] = camera_2d}
	if name == "Camera3D" {world.cameras_3d[entity] = camera_3d}
	if name == "OrbitCamera3D" {world.orbit_cameras_3d[entity] = orbit_camera_3d}
	if name == "AudioListener" {world.audio_listeners[entity] = audio_listener}
	if name == "NavGrid2D" {world.nav_grids_2d[entity] = nav_grid_2d}
	if name == "NavAgent2D" {world.nav_agents_2d[entity] = nav_agent_2d}
	record_component_change(world, entity, name, .Changed if already_present else .Added)
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

	record_component_change(world, entity, name, .Removed)
	if name == "RigidBody2D" || name == "BoxCollider2D" || name == "CircleCollider2D" {
		physics_2d_remove_entity(world, entity)
	}
	if name == "RigidBody3D" || name == "BoxCollider" || name == "SphereCollider" {
		physics_3d_remove_entity(world, entity)
	}
	delete_key(&components, entity)
	world.component_data[name] = components
	if typed_components, typed_found := world.typed_component_data[name]; typed_found {
		delete_key(&typed_components, entity)
		world.typed_component_data[name] = typed_components
	}
	if name == "Transform" {
		delete_key(&world.transforms, entity)
	}
	if name == "SpriteRenderer" {delete_key(&world.sprite_renderers, entity)}
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
	if name == "AmbientLight" {delete_key(&world.ambient_lights, entity)}
	if name == "DirectionalLight" {delete_key(&world.directional_lights, entity)}
	if name == "PointLight" {delete_key(&world.point_lights, entity)}
	if name == "SpotLight" {delete_key(&world.spot_lights, entity)}
	if name == "TilemapRenderer" {
		destroy_tilemap_renderer_storage(world.tilemap_renderers[entity])
		delete_key(&world.tilemap_renderers, entity)
	}
	if name == "TextRenderer" {delete_key(&world.text_renderers, entity)}
	if name == "TilemapCollider" {
		destroy_tilemap_collider_storage(world.tilemap_colliders[entity])
		delete_key(&world.tilemap_colliders, entity)
	}
	if name == "TopDownController" {delete_key(&world.top_down_controllers, entity)}
	if name == "RigidBody2D" {delete_key(&world.rigid_bodies_2d, entity)}
	if name == "BoxCollider2D" {delete_key(&world.box_colliders_2d, entity)}
	if name == "CircleCollider2D" {delete_key(&world.circle_colliders_2d, entity)}
	if name ==
	   "RigidBody3D" {delete_key(&world.rigid_bodies_3d, entity); delete_key(&world.box3d_bodies, entity)}
	if name == "BoxCollider" {delete_key(&world.box_colliders, entity)}
	if name == "SphereCollider" {delete_key(&world.sphere_colliders, entity)}
	if name == "CharacterController" {delete_key(&world.character_controllers, entity)}
	if name == "Orbit" {delete_key(&world.orbits, entity)}
	if name == "Rotator" {delete_key(&world.rotators, entity)}
	if name == "Camera2D" {delete_key(&world.cameras_2d, entity)}
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
