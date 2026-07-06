package ecs

import "core:encoding/json"
import b2 "vendor:box2d"

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

next_world_generation: u32 = 1

// Default is the only universally named layer. Projects may define additional
// names for bits 1 through 63 in project.json.
Default_Layer      : u8  : 0
Default_Layer_Mask : u64 : u64(1) << Default_Layer

World :: struct {
	generation:      u32,
	next_entity:     u32,
	entity_count:    int,
	entities:        map[Entity]bool,
	entity_ids:      map[Entity]string,
	entities_by_id:  map[string]Entity,
	entity_names:    map[Entity]string,
	entity_tags:     map[Entity]string,
	layer_masks:     map[Entity]u64,
	parents:         map[Entity]Entity,
	// Hierarchy indexes are rebuilt only when parenting changes. Rendering can
	// then walk direct child lists instead of repeatedly scanning every parent.
	roots:           [dynamic]Entity,
	children_by_parent: map[Entity][dynamic]Entity,
	hierarchy_dirty: bool,
	scene_json:       json.Value,
	component_data:  map[string]map[Entity]json.Value,
	component_instance_data: map[string]map[Component_Instance]json.Value,
	transforms:       map[Entity]Transform,
	sprite_renderers: map[Entity]SpriteRenderer,
	mesh_renderers:   map[Entity]MeshRenderer,
	sphere_renderers: map[Entity]SphereRenderer,
	model_renderers:  map[Entity]ModelRenderer,
	tilemap_renderers: map[Entity]TilemapRenderer,
	text_renderers:    map[Entity]TextRenderer,
	tilemap_colliders: map[Entity]TilemapCollider,
	top_down_controllers: map[Entity]TopDownController,
	rigid_bodies_2d: map[Entity]RigidBody2D,
	box_colliders_2d: map[Entity]BoxCollider2D,
	circle_colliders_2d: map[Entity]CircleCollider2D,
	physics_2d_accumulator: f32,
	box2d_world: b2.WorldId,
	box2d_bodies: map[Entity]b2.BodyId,
	box_colliders:    map[Entity]BoxCollider,
	sphere_colliders: map[Entity]SphereCollider,
	character_controllers: map[Entity]CharacterController,
	orbits:           map[Entity]Orbit,
	rotators:         map[Entity]Rotator,
	cameras_2d:       map[Entity]Camera2D,
	cameras_3d:       map[Entity]Camera3D,
	audio_listeners:  map[Entity]AudioListener,
	audio_players:    map[Component_Instance]AudioPlayer,
	nav_grids_2d:     map[Entity]NavGrid2D,
	nav_agents_2d:    map[Entity]NavAgent2D,
}

init :: proc() -> World {
	generation := next_world_generation
	next_world_generation += 1
	if next_world_generation == 0 {
		next_world_generation = 1
	}
	return World{
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
		transforms = make(map[Entity]Transform),
		sprite_renderers = make(map[Entity]SpriteRenderer),
		mesh_renderers = make(map[Entity]MeshRenderer),
		sphere_renderers = make(map[Entity]SphereRenderer),
		model_renderers = make(map[Entity]ModelRenderer),
		tilemap_renderers = make(map[Entity]TilemapRenderer),
		text_renderers = make(map[Entity]TextRenderer),
		tilemap_colliders = make(map[Entity]TilemapCollider),
		top_down_controllers = make(map[Entity]TopDownController),
		rigid_bodies_2d = make(map[Entity]RigidBody2D),
		box_colliders_2d = make(map[Entity]BoxCollider2D),
		circle_colliders_2d = make(map[Entity]CircleCollider2D),
		box2d_bodies = make(map[Entity]b2.BodyId),
		box_colliders = make(map[Entity]BoxCollider),
		sphere_colliders = make(map[Entity]SphereCollider),
		character_controllers = make(map[Entity]CharacterController),
		orbits = make(map[Entity]Orbit),
		rotators = make(map[Entity]Rotator),
		cameras_2d = make(map[Entity]Camera2D),
		cameras_3d = make(map[Entity]Camera3D),
		audio_listeners = make(map[Entity]AudioListener),
		audio_players = make(map[Component_Instance]AudioPlayer),
		nav_grids_2d = make(map[Entity]NavGrid2D),
		nav_agents_2d = make(map[Entity]NavAgent2D),
	}
}

// set_parent makes child inherit its parent's scene transform. Passing Entity(0)
// makes the entity a scene root.
set_parent :: proc(world: ^World, child, parent: Entity) -> bool {
	if !is_alive(world, child) || (parent != Entity(0) && !is_alive(world, parent)) || child == parent {
		return false
	}
	if parent == Entity(0) {
		delete_key(&world.parents, child)
	} else {
		world.parents[child] = parent
	}
	world.hierarchy_dirty = true
	return true
}

// set_scene_json stores the full root scene JSON document on the World. Scene
// loading calls this so game code can access scene-owned global settings.
set_scene_json :: proc(world: ^World, value: json.Value) {
	world.scene_json = value
}

get_parent :: proc(world: ^World, entity: Entity) -> (Entity, bool) {
	parent, found := world.parents[entity]
	return parent, found
}

// root_entities and child_entities expose cached hierarchy indexes to render
// systems. The indexes are rebuilt only when entities are created or reparented.
root_entities :: proc(world: ^World) -> []Entity {
	ensure_hierarchy_indexes(world)
	return world.roots[:]
}

child_entities :: proc(world: ^World, parent: Entity) -> []Entity {
	ensure_hierarchy_indexes(world)
	children, found := world.children_by_parent[parent]
	if !found { return nil }
	return children[:]
}

ensure_hierarchy_indexes :: proc(world: ^World) {
	if !world.hierarchy_dirty { return }
	// Reparenting is uncommon. Replacing these compact indexes keeps the hot
	// rendering path allocation-free and avoids a full parent-map scan per node.
	world.roots = make([dynamic]Entity)
	world.children_by_parent = make(map[Entity][dynamic]Entity)
	for entity in world.entities {
		parent, has_parent := world.parents[entity]
		if !has_parent {
			append(&world.roots, entity)
			continue
		}
		children, found := world.children_by_parent[parent]
		if !found { children = make([dynamic]Entity) }
		append(&children, entity)
		world.children_by_parent[parent] = children
	}
	world.hierarchy_dirty = false
}

create_entity :: proc(world: ^World) -> Entity {
	if world.next_entity == 0 {
		return Entity(0)
	}
	entity := make_entity(world.generation, world.next_entity)
	world.next_entity += 1
	world.entity_count += 1
	world.entities[entity] = true
	world.hierarchy_dirty = true
	// Every entity starts in the Default layer (bit 0).
	world.layer_masks[entity] = Default_Layer_Mask
	return entity
}

make_entity :: proc(generation, index: u32) -> Entity {
	return Entity((u64(generation) << 32) | u64(index))
}

entity_index :: proc(entity: Entity) -> u32 {
	return u32(u64(entity) & 0xffffffff)
}

entity_generation :: proc(entity: Entity) -> u32 {
	return u32(u64(entity) >> 32)
}

is_alive :: proc(world: ^World, entity: Entity) -> bool {
	return entity != Entity(0) &&
	       entity_generation(entity) == world.generation &&
	       world.entities[entity]
}

// set_entity_metadata assigns scene-owned identity and filtering data. Non-empty
// IDs must be unique within a World so game code can resolve and cache an Entity
// handle. Names and tags may be empty or duplicated. A zero layer mask is not
// valid because it would make an entity invisible to every layer-filtered system.
set_entity_metadata :: proc(world: ^World, entity: Entity, id, name, tag: string, layer_mask: u64) -> bool {
	if !is_alive(world, entity) || layer_mask == 0 {
		return false
	}
	if id != "" {
		if existing, found := world.entities_by_id[id]; found && existing != entity {
			return false
		}
		world.entities_by_id[id] = entity
	}
	world.entity_ids[entity] = id
	world.entity_names[entity] = name
	world.entity_tags[entity] = tag
	world.layer_masks[entity] = layer_mask
	return true
}

entity_id :: proc(world: ^World, entity: Entity) -> (string, bool) {
	value, found := world.entity_ids[entity]
	return value, found
}

// find_entity_by_id resolves a non-empty scene ID to its World-local runtime
// handle. Cache the returned Entity in game code and resolve it again after a
// scene reload, because handles are only valid for their originating World.
find_entity_by_id :: proc(world: ^World, id: string) -> (Entity, bool) {
	if id == "" {
		return Entity(0), false
	}
	entity, found := world.entities_by_id[id]
	return entity, found
}

// entity_ref returns a persistent, JSON-facing reference for a scene entity.
// Unlike Entity, this value can be resolved again after the World is replaced.
// Runtime-only entities without an ID cannot produce a persistent reference.
entity_ref :: proc(world: ^World, entity: Entity) -> (Entity_Ref, bool) {
	id, found := entity_id(world, entity)
	if !found || id == "" {
		return {}, false
	}
	return Entity_Ref{id = id}, true
}

entity_ref_from_id :: proc(id: string) -> (Entity_Ref, bool) {
	if id == "" {
		return {}, false
	}
	return Entity_Ref{id = id}, true
}

resolve_entity_ref :: proc(world: ^World, ref: Entity_Ref) -> (Entity, bool) {
	return find_entity_by_id(world, ref.id)
}

entity_name :: proc(world: ^World, entity: Entity) -> (string, bool) {
	value, found := world.entity_names[entity]
	return value, found
}

entity_tag :: proc(world: ^World, entity: Entity) -> (string, bool) {
	value, found := world.entity_tags[entity]
	return value, found
}

set_entity_tag :: proc(world: ^World, entity: Entity, tag: string) -> bool {
	if !is_alive(world, entity) { return false }
	world.entity_tags[entity] = tag
	return true
}

entity_layer_mask :: proc(world: ^World, entity: Entity) -> (u64, bool) {
	value, found := world.layer_masks[entity]
	return value, found
}

set_entity_layer_mask :: proc(world: ^World, entity: Entity, layer_mask: u64) -> bool {
	if !is_alive(world, entity) || layer_mask == 0 { return false }
	world.layer_masks[entity] = layer_mask
	return true
}

has_tag :: proc(world: ^World, entity: Entity, tag: string) -> bool {
	entity_tag, found := entity_tag(world, entity)
	return found && entity_tag == tag
}

is_in_layer_mask :: proc(world: ^World, entity: Entity, layer_mask: u64) -> bool {
	entity_mask, found := entity_layer_mask(world, entity)
	return found && (entity_mask & layer_mask) != 0
}

// add_component attaches JSON data to an entity. Components must be explicitly
// registered so misspelled or unsupported component names fail at load time.
add_component :: proc(world: ^World, registry: ^Component_Registry, entity: Entity, name: string, data: json.Value) -> bool {
	if !is_alive(world, entity) || !has_component(registry, name) {
		return false
	}
	descriptor, _ := component_descriptor(registry, name)
	if descriptor.allow_multiple {
		instances, ok := data.(json.Object)
		if !ok || len(instances) == 0 { return false }

		parsed_audio := make(map[Component_Instance]AudioPlayer, context.temp_allocator)
		for instance_name, instance_data in instances {
			if len(instance_name) == 0 { return false }
			key := Component_Instance{entity = entity, name = instance_name}
			if name == "AudioPlayer" {
				value, parsed := audio_player_from_json(instance_data)
				if !parsed { return false }
				parsed_audio[key] = value
			}
		}

		values, values_found := world.component_instance_data[name]
		if !values_found { values = make(map[Component_Instance]json.Value) }
		for instance_name, instance_data in instances {
			key := Component_Instance{entity = entity, name = instance_name}
			values[key] = instance_data
			if name == "AudioPlayer" { world.audio_players[key] = parsed_audio[key] }
		}
		world.component_instance_data[name] = values
		components, components_found := world.component_data[name]
		if !components_found { components = make(map[Entity]json.Value) }
		components[entity] = data
		world.component_data[name] = components
		return true
	}

	transform: Transform
	sprite_renderer: SpriteRenderer
	mesh_renderer: MeshRenderer
	sphere_renderer: SphereRenderer
	model_renderer: ModelRenderer
	tilemap_renderer: TilemapRenderer
	text_renderer: TextRenderer
	tilemap_collider: TilemapCollider
	top_down_controller: TopDownController
	rigid_body_2d: RigidBody2D
	box_collider_2d: BoxCollider2D
	circle_collider_2d: CircleCollider2D
	box_collider: BoxCollider
	sphere_collider: SphereCollider
	character_controller: CharacterController
	orbit: Orbit
	rotator: Rotator
	camera_2d: Camera2D
	camera_3d: Camera3D
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
	if name == "SpriteRenderer" { sprite_renderer, parse_ok = sprite_renderer_from_json(data); if !parse_ok { return false } }
	if name == "MeshRenderer" { mesh_renderer, parse_ok = mesh_renderer_from_json(data); if !parse_ok { return false } }
	if name == "SphereRenderer" { sphere_renderer, parse_ok = sphere_renderer_from_json(data); if !parse_ok { return false } }
	if name == "ModelRenderer" { model_renderer, parse_ok = model_renderer_from_json(data); if !parse_ok { return false } }
	if name == "TilemapRenderer" { tilemap_renderer, parse_ok = tilemap_renderer_from_json(data); if !parse_ok { return false } }
	if name == "TextRenderer" { text_renderer, parse_ok = text_renderer_from_json(data); if !parse_ok { return false } }
	if name == "TilemapCollider" { tilemap_collider, parse_ok = tilemap_collider_from_json(data); if !parse_ok { return false } }
	if name == "TopDownController" { top_down_controller, parse_ok = top_down_controller_from_json(data); if !parse_ok { return false } }
	if name == "RigidBody2D" { rigid_body_2d, parse_ok = rigid_body_2d_from_json(data); if !parse_ok { return false } }
	if name == "BoxCollider2D" { box_collider_2d, parse_ok = box_collider_2d_from_json(data); if !parse_ok { return false } }
	if name == "CircleCollider2D" { circle_collider_2d, parse_ok = circle_collider_2d_from_json(data); if !parse_ok { return false } }
	if name == "BoxCollider" { box_collider, parse_ok = box_collider_from_json(data); if !parse_ok { return false } }
	if name == "SphereCollider" { sphere_collider, parse_ok = sphere_collider_from_json(data); if !parse_ok { return false } }
	if name == "CharacterController" { character_controller, parse_ok = character_controller_from_json(data); if !parse_ok { return false } }
	if name == "Orbit" { orbit, parse_ok = orbit_from_json(data); if !parse_ok { return false } }
	if name == "Rotator" { rotator, parse_ok = rotator_from_json(data); if !parse_ok { return false } }
	if name == "Camera2D" { camera_2d, parse_ok = camera_2d_from_json(data); if !parse_ok { return false } }
	if name == "Camera3D" { camera_3d, parse_ok = camera_3d_from_json(data); if !parse_ok { return false } }
	if name == "AudioListener" { audio_listener, parse_ok = audio_listener_from_json(data); if !parse_ok { return false } }
	if name == "NavGrid2D" { nav_grid_2d, parse_ok = nav_grid_2d_from_json(data); if !parse_ok { return false } }
	if name == "NavAgent2D" { nav_agent_2d, parse_ok = nav_agent_2d_from_json(data); if !parse_ok { return false } }

	components, component_type_found := world.component_data[name]
	if !component_type_found {
		components = make(map[Entity]json.Value)
	}
	components[entity] = data
	world.component_data[name] = components

	if name == "Transform" {
		world.transforms[entity] = transform
	}
	if name == "SpriteRenderer" { world.sprite_renderers[entity] = sprite_renderer }
	if name == "MeshRenderer" { world.mesh_renderers[entity] = mesh_renderer }
	if name == "SphereRenderer" { world.sphere_renderers[entity] = sphere_renderer }
	if name == "ModelRenderer" { world.model_renderers[entity] = model_renderer }
	if name == "TilemapRenderer" { world.tilemap_renderers[entity] = tilemap_renderer }
	if name == "TextRenderer" { world.text_renderers[entity] = text_renderer }
	if name == "TilemapCollider" { world.tilemap_colliders[entity] = tilemap_collider }
	if name == "TopDownController" { world.top_down_controllers[entity] = top_down_controller }
	if name == "RigidBody2D" { world.rigid_bodies_2d[entity] = rigid_body_2d }
	if name == "BoxCollider2D" { world.box_colliders_2d[entity] = box_collider_2d }
	if name == "CircleCollider2D" { world.circle_colliders_2d[entity] = circle_collider_2d }
	if name == "BoxCollider" { world.box_colliders[entity] = box_collider }
	if name == "SphereCollider" { world.sphere_colliders[entity] = sphere_collider }
	if name == "CharacterController" { world.character_controllers[entity] = character_controller }
	if name == "Orbit" { world.orbits[entity] = orbit }
	if name == "Rotator" { world.rotators[entity] = rotator }
	if name == "Camera2D" { world.cameras_2d[entity] = camera_2d }
	if name == "Camera3D" { world.cameras_3d[entity] = camera_3d }
	if name == "AudioListener" { world.audio_listeners[entity] = audio_listener }
	if name == "NavGrid2D" { world.nav_grids_2d[entity] = nav_grid_2d }
	if name == "NavAgent2D" { world.nav_agents_2d[entity] = nav_agent_2d }
	return true
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

	delete_key(&components, entity)
	world.component_data[name] = components
	if name == "Transform" {
		delete_key(&world.transforms, entity)
	}
	if name == "SpriteRenderer" { delete_key(&world.sprite_renderers, entity) }
	if name == "MeshRenderer" { delete_key(&world.mesh_renderers, entity) }
	if name == "SphereRenderer" { delete_key(&world.sphere_renderers, entity) }
	if name == "ModelRenderer" { delete_key(&world.model_renderers, entity) }
	if name == "TilemapRenderer" { delete_key(&world.tilemap_renderers, entity) }
	if name == "TextRenderer" { delete_key(&world.text_renderers, entity) }
	if name == "TilemapCollider" { delete_key(&world.tilemap_colliders, entity) }
	if name == "TopDownController" { delete_key(&world.top_down_controllers, entity) }
	if name == "RigidBody2D" { delete_key(&world.rigid_bodies_2d, entity) }
	if name == "BoxCollider2D" { delete_key(&world.box_colliders_2d, entity) }
	if name == "CircleCollider2D" { delete_key(&world.circle_colliders_2d, entity) }
	if name == "BoxCollider" { delete_key(&world.box_colliders, entity) }
	if name == "SphereCollider" { delete_key(&world.sphere_colliders, entity) }
	if name == "CharacterController" { delete_key(&world.character_controllers, entity) }
	if name == "Orbit" { delete_key(&world.orbits, entity) }
	if name == "Rotator" { delete_key(&world.rotators, entity) }
	if name == "Camera2D" { delete_key(&world.cameras_2d, entity) }
	if name == "Camera3D" { delete_key(&world.cameras_3d, entity) }
	if name == "AudioListener" { delete_key(&world.audio_listeners, entity) }
	if name == "AudioPlayer" {
		for key in world.audio_players {
			if key.entity == entity { delete_key(&world.audio_players, key) }
		}
	}
	if instances, instances_found := world.component_instance_data[name]; instances_found {
		for key in instances {
			if key.entity == entity { delete_key(&instances, key) }
		}
		world.component_instance_data[name] = instances
	}
	if name == "NavGrid2D" { delete_key(&world.nav_grids_2d, entity) }
	if name == "NavAgent2D" { delete_key(&world.nav_agents_2d, entity) }
	return true
}

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
	if !found { return nil }
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

get_component_instance :: proc(world: ^World, entity: Entity, component_name, instance_name: string) -> (json.Value, bool) {
	instances, found := world.component_instance_data[component_name]
	if !found { return {}, false }
	value, instance_found := instances[Component_Instance{entity = entity, name = instance_name}]
	return value, instance_found
}

component_instance_names :: proc(world: ^World, entity: Entity, component_name: string) -> []string {
	instances, found := world.component_instance_data[component_name]
	if !found { return nil }
	result := make([dynamic]string, context.temp_allocator)
	for key in instances {
		if key.entity == entity { append(&result, key.name) }
	}
	return result[:]
}

remove_component_instance :: proc(world: ^World, entity: Entity, component_name, instance_name: string) -> bool {
	instances, found := world.component_instance_data[component_name]
	if !found { return false }
	key := Component_Instance{entity = entity, name = instance_name}
	if _, instance_found := instances[key]; !instance_found { return false }
	delete_key(&instances, key)
	world.component_instance_data[component_name] = instances
	if component_name == "AudioPlayer" { delete_key(&world.audio_players, key) }
	has_remaining := false
	for candidate in instances {
		if candidate.entity == entity { has_remaining = true; break }
	}
	if !has_remaining {
		if components, components_found := world.component_data[component_name]; components_found {
			delete_key(&components, entity)
			world.component_data[component_name] = components
		}
	}
	return true
}

// get_scene_json exposes the full root scene JSON document used to create this
// World, including game-defined fields outside the entity list.
get_scene_json :: proc(world: ^World) -> json.Value { return world.scene_json }

// get_scene_value returns a top-level scene JSON value by key.
get_scene_value :: proc(world: ^World, key: string) -> (json.Value, bool) {
	object, ok := world.scene_json.(json.Object)
	if !ok { return {}, false }
	value, found := object[key]
	return value, found
}

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

get_sprite_renderer :: proc(world: ^World, entity: Entity) -> (SpriteRenderer, bool) { value, found := world.sprite_renderers[entity]; return value, found }
set_sprite_renderer :: proc(world: ^World, entity: Entity, value: SpriteRenderer) -> bool { if !has_component_data(world, entity, "SpriteRenderer") { return false }; world.sprite_renderers[entity] = value; return true }
get_mesh_renderer :: proc(world: ^World, entity: Entity) -> (MeshRenderer, bool) { value, found := world.mesh_renderers[entity]; return value, found }
set_mesh_renderer :: proc(world: ^World, entity: Entity, value: MeshRenderer) -> bool { if !has_component_data(world, entity, "MeshRenderer") { return false }; world.mesh_renderers[entity] = value; return true }
get_sphere_renderer :: proc(world: ^World, entity: Entity) -> (SphereRenderer, bool) { value, found := world.sphere_renderers[entity]; return value, found }
set_sphere_renderer :: proc(world: ^World, entity: Entity, value: SphereRenderer) -> bool { if !has_component_data(world, entity, "SphereRenderer") { return false }; world.sphere_renderers[entity] = value; return true }
get_model_renderer :: proc(world: ^World, entity: Entity) -> (ModelRenderer, bool) { value, found := world.model_renderers[entity]; return value, found }
set_model_renderer :: proc(world: ^World, entity: Entity, value: ModelRenderer) -> bool { if !has_component_data(world, entity, "ModelRenderer") { return false }; world.model_renderers[entity] = value; return true }
get_tilemap_renderer :: proc(world: ^World, entity: Entity) -> (TilemapRenderer, bool) { value, found := world.tilemap_renderers[entity]; return value, found }
set_tilemap_renderer :: proc(world: ^World, entity: Entity, value: TilemapRenderer) -> bool { if !has_component_data(world, entity, "TilemapRenderer") { return false }; world.tilemap_renderers[entity] = value; return true }
get_text_renderer :: proc(world: ^World, entity: Entity) -> (TextRenderer, bool) { value, found := world.text_renderers[entity]; return value, found }
set_text_renderer :: proc(world: ^World, entity: Entity, value: TextRenderer) -> bool { if !has_component_data(world, entity, "TextRenderer") { return false }; world.text_renderers[entity] = value; return true }
get_tilemap_collider :: proc(world: ^World, entity: Entity) -> (TilemapCollider, bool) { value, found := world.tilemap_colliders[entity]; return value, found }
set_tilemap_collider :: proc(world: ^World, entity: Entity, value: TilemapCollider) -> bool { if !has_component_data(world, entity, "TilemapCollider") { return false }; world.tilemap_colliders[entity] = value; return true }
get_top_down_controller :: proc(world: ^World, entity: Entity) -> (TopDownController, bool) { value, found := world.top_down_controllers[entity]; return value, found }
set_top_down_controller :: proc(world: ^World, entity: Entity, value: TopDownController) -> bool { if !has_component_data(world, entity, "TopDownController") { return false }; world.top_down_controllers[entity] = value; return true }
get_rigid_body_2d :: proc(world: ^World, entity: Entity) -> (RigidBody2D, bool) { value, found := world.rigid_bodies_2d[entity]; return value, found }
set_rigid_body_2d :: proc(world: ^World, entity: Entity, value: RigidBody2D) -> bool { if !has_component_data(world, entity, "RigidBody2D") { return false }; world.rigid_bodies_2d[entity] = value; return true }
get_box_collider_2d :: proc(world: ^World, entity: Entity) -> (BoxCollider2D, bool) { value, found := world.box_colliders_2d[entity]; return value, found }
get_circle_collider_2d :: proc(world: ^World, entity: Entity) -> (CircleCollider2D, bool) { value, found := world.circle_colliders_2d[entity]; return value, found }
get_box_collider :: proc(world: ^World, entity: Entity) -> (BoxCollider, bool) { value, found := world.box_colliders[entity]; return value, found }
set_box_collider :: proc(world: ^World, entity: Entity, value: BoxCollider) -> bool { if !has_component_data(world, entity, "BoxCollider") { return false }; world.box_colliders[entity] = value; return true }
get_sphere_collider :: proc(world: ^World, entity: Entity) -> (SphereCollider, bool) { value, found := world.sphere_colliders[entity]; return value, found }
set_sphere_collider :: proc(world: ^World, entity: Entity, value: SphereCollider) -> bool { if !has_component_data(world, entity, "SphereCollider") { return false }; world.sphere_colliders[entity] = value; return true }
get_character_controller :: proc(world: ^World, entity: Entity) -> (CharacterController, bool) { value, found := world.character_controllers[entity]; return value, found }
set_character_controller :: proc(world: ^World, entity: Entity, value: CharacterController) -> bool { if !has_component_data(world, entity, "CharacterController") { return false }; world.character_controllers[entity] = value; return true }
get_orbit :: proc(world: ^World, entity: Entity) -> (Orbit, bool) { value, found := world.orbits[entity]; return value, found }
set_orbit :: proc(world: ^World, entity: Entity, value: Orbit) -> bool { if !has_component_data(world, entity, "Orbit") { return false }; world.orbits[entity] = value; return true }
get_rotator :: proc(world: ^World, entity: Entity) -> (Rotator, bool) { value, found := world.rotators[entity]; return value, found }
set_rotator :: proc(world: ^World, entity: Entity, value: Rotator) -> bool { if !has_component_data(world, entity, "Rotator") { return false }; world.rotators[entity] = value; return true }
get_camera_2d :: proc(world: ^World, entity: Entity) -> (Camera2D, bool) { value, found := world.cameras_2d[entity]; return value, found }
set_camera_2d :: proc(world: ^World, entity: Entity, value: Camera2D) -> bool { if !has_component_data(world, entity, "Camera2D") { return false }; world.cameras_2d[entity] = value; return true }
get_camera_3d :: proc(world: ^World, entity: Entity) -> (Camera3D, bool) { value, found := world.cameras_3d[entity]; return value, found }
set_camera_3d :: proc(world: ^World, entity: Entity, value: Camera3D) -> bool { if !has_component_data(world, entity, "Camera3D") { return false }; world.cameras_3d[entity] = value; return true }
get_audio_listener :: proc(world: ^World, entity: Entity) -> (AudioListener, bool) { value, found := world.audio_listeners[entity]; return value, found }
set_audio_listener :: proc(world: ^World, entity: Entity, value: AudioListener) -> bool { if !has_component_data(world, entity, "AudioListener") { return false }; world.audio_listeners[entity] = value; return true }
get_audio_player :: proc(world: ^World, entity: Entity, instance_name: string) -> (AudioPlayer, bool) {
	value, found := world.audio_players[Component_Instance{entity = entity, name = instance_name}]
	return value, found
}
set_audio_player :: proc(world: ^World, entity: Entity, instance_name: string, value: AudioPlayer) -> bool {
	key := Component_Instance{entity = entity, name = instance_name}
	if _, found := world.audio_players[key]; !found { return false }
	world.audio_players[key] = value
	return true
}
get_nav_grid_2d :: proc(world: ^World, entity: Entity) -> (NavGrid2D, bool) { value, found := world.nav_grids_2d[entity]; return value, found }
set_nav_grid_2d :: proc(world: ^World, entity: Entity, value: NavGrid2D) -> bool { if !has_component_data(world, entity, "NavGrid2D") { return false }; world.nav_grids_2d[entity] = value; return true }
get_nav_agent_2d :: proc(world: ^World, entity: Entity) -> (NavAgent2D, bool) { value, found := world.nav_agents_2d[entity]; return value, found }
set_nav_agent_2d :: proc(world: ^World, entity: Entity, value: NavAgent2D) -> bool { if !has_component_data(world, entity, "NavAgent2D") { return false }; world.nav_agents_2d[entity] = value; return true }

active_camera_2d :: proc(world: ^World) -> (Entity, Camera2D, bool) {
	for entity, camera in world.cameras_2d {
		if camera.active { return entity, camera, true }
	}
	return Entity(0), {}, false
}

active_camera_3d :: proc(world: ^World) -> (Entity, Camera3D, bool) {
	for entity, camera in world.cameras_3d {
		if camera.active { return entity, camera, true }
	}
	return Entity(0), {}, false
}

set_active_camera_2d :: proc(world: ^World, entity: Entity) -> bool {
	if _, found := world.cameras_2d[entity]; !found { return false }
	for candidate, &camera in world.cameras_2d {
		camera.active = candidate == entity
		world.cameras_2d[candidate] = camera
	}
	return true
}

set_active_camera_3d :: proc(world: ^World, entity: Entity) -> bool {
	if _, found := world.cameras_3d[entity]; !found { return false }
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
		if !listener.active { continue }
		if found { return Entity(0), {}, false }
		selected_entity = entity
		selected_listener = listener
		found = true
	}
	return selected_entity, selected_listener, found
}

set_active_audio_listener :: proc(world: ^World, entity: Entity) -> bool {
	if _, found := world.audio_listeners[entity]; !found { return false }
	for candidate, &listener in world.audio_listeners {
		listener.active = candidate == entity
		world.audio_listeners[candidate] = listener
	}
	return true
}
