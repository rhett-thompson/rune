package ecs

import "core:mem"
import "rune:geometry"
import "rune:memory"

Memory_Stats :: struct {
	entity_count, component_count, owned_json_count, change_records, retained_strings: int,
	world_bytes, map_bytes, owned_json_bytes, typed_value_bytes: u64,
	static_mesh_bytes, hierarchy_bytes: u64,
	scene_arena, resource_arena, typed_arenas: memory.Arena_Stats,
}

// An on-demand snapshot of known backing buffers. Nested subsystem buffers,
// native physics allocations, and allocator overhead are not included.
memory_stats :: proc(world: ^World) -> Memory_Stats {
	if world == nil {return {}}
	result := Memory_Stats{
		entity_count = world.entity_count, owned_json_count = len(world.owned_component_json),
		change_records = len(world.component_changes), retained_strings = len(world.scene_strings),
		world_bytes = size_of(World), scene_arena = memory.arena_stats(world.scene_data_arena),
		resource_arena = memory.arena_stats(world.typed_component_arena),
	}
	result.map_bytes += memory.map_bytes(world.static_meshes)
	result.map_bytes += memory.map_bytes(world.character_controllers_3d)
	result.map_bytes += memory.map_bytes(world.character_controller_states_3d)
	result.map_bytes += memory.map_bytes(world.character_controllers_2d)
	result.map_bytes += memory.map_bytes(world.character_controller_states_2d)
	result.map_bytes += memory.map_bytes(world.polygon_colliders_2d)
	result.map_bytes += memory.map_bytes(world.segment_colliders_2d)
	result.map_bytes += memory.map_bytes(world.capsule_colliders_2d)
	result.map_bytes += memory.map_bytes(world.disabled_entities)
	result.map_bytes += memory.map_bytes(world.lifetime_elapsed)
	result.map_bytes += memory.map_bytes(world.lifetimes)
	result.map_bytes += memory.map_bytes(world.shape_renderers_2d)
	result.map_bytes += memory.map_bytes(world.particle_emitters_2d)
	result.map_bytes += memory.map_bytes(world.particle_states_2d)
	result.map_bytes += memory.map_bytes(world.model_animators)
	result.map_bytes += memory.map_bytes(world.model_animation_states)
	result.map_bytes += memory.map_bytes(world.entities)
	result.map_bytes += memory.map_bytes(world.entity_ids)
	result.map_bytes += memory.map_bytes(world.entities_by_id)
	result.map_bytes += memory.map_bytes(world.entity_names)
	result.map_bytes += memory.map_bytes(world.entity_tags)
	result.map_bytes += memory.map_bytes(world.layer_masks)
	result.map_bytes += memory.map_bytes(world.parents)
	result.map_bytes += memory.map_bytes(world.children_by_parent)
	result.map_bytes += memory.map_bytes(world.component_data)
	result.map_bytes += memory.map_bytes(world.owned_component_json)
	result.map_bytes += memory.map_bytes(world.component_instance_data)
	result.map_bytes += memory.map_bytes(world.typed_component_data)
	result.map_bytes += memory.map_bytes(world.typed_value_arenas)
	result.map_bytes += memory.map_bytes(world.component_descriptors)
	result.map_bytes += memory.map_bytes(world.component_names_by_type)
	result.map_bytes += memory.map_bytes(world.component_changes)
	result.map_bytes += memory.map_bytes(world.resources)
	result.map_bytes += memory.map_bytes(world.scene_strings)
	result.map_bytes += memory.map_bytes(world.transforms)
	result.map_bytes += memory.map_bytes(world.sprite_renderers)
	result.map_bytes += memory.map_bytes(world.sprite_animators)
	result.map_bytes += memory.map_bytes(world.sprite_animation_states)
	result.map_bytes += memory.map_bytes(world.mesh_renderers)
	result.map_bytes += memory.map_bytes(world.sphere_renderers)
	result.map_bytes += memory.map_bytes(world.model_renderers)
	result.map_bytes += memory.map_bytes(world.skyboxes)
	result.map_bytes += memory.map_bytes(world.terrains)
	result.map_bytes += memory.map_bytes(world.terrain_states)
	result.map_bytes += memory.map_bytes(world.post_processing)
	result.map_bytes += memory.map_bytes(world.ambient_lights)
	result.map_bytes += memory.map_bytes(world.directional_lights)
	result.map_bytes += memory.map_bytes(world.point_lights)
	result.map_bytes += memory.map_bytes(world.spot_lights)
	result.map_bytes += memory.map_bytes(world.tilemap_renderers)
	result.map_bytes += memory.map_bytes(world.text_renderers)
	result.map_bytes += memory.map_bytes(world.tilemap_colliders)
	result.map_bytes += memory.map_bytes(world.top_down_controllers)
	result.map_bytes += memory.map_bytes(world.rigid_bodies_2d)
	result.map_bytes += memory.map_bytes(world.box_colliders_2d)
	result.map_bytes += memory.map_bytes(world.circle_colliders_2d)
	result.map_bytes += memory.map_bytes(world.one_way_contacts_2d)
	result.map_bytes += memory.map_bytes(world.one_way_shapes_2d)
	result.map_bytes += memory.map_bytes(world.box2d_bodies)
	result.map_bytes += memory.map_bytes(world.rigid_bodies_3d)
	result.map_bytes += memory.map_bytes(world.box3d_bodies)
	result.map_bytes += memory.map_bytes(world.box_colliders)
	result.map_bytes += memory.map_bytes(world.sphere_colliders)
	result.map_bytes += memory.map_bytes(world.character_controllers)
	result.map_bytes += memory.map_bytes(world.orbits)
	result.map_bytes += memory.map_bytes(world.rotators)
	result.map_bytes += memory.map_bytes(world.cameras_2d)
	result.map_bytes += memory.map_bytes(world.camera_follows_2d)
	result.map_bytes += memory.map_bytes(world.cameras_3d)
	result.map_bytes += memory.map_bytes(world.orbit_cameras_3d)
	result.map_bytes += memory.map_bytes(world.audio_listeners)
	result.map_bytes += memory.map_bytes(world.audio_players)
	result.map_bytes += memory.map_bytes(world.nav_grids_2d)
	result.map_bytes += memory.map_bytes(world.nav_agents_2d)
	for _, values in world.component_data {
		result.component_count += len(values)
		result.map_bytes += memory.map_bytes(values)
	}
	for _, values in world.component_instance_data {result.map_bytes += memory.map_bytes(values)}
	for _, values in world.typed_component_data {
		result.map_bytes += memory.map_bytes(values)
		for _, value in values {
			if world.typed_value_arenas[value.data] == nil {result.typed_value_bytes += u64(type_info_of(value.id).size)}
		}
	}
	for _, values in world.scene_source.components {result.map_bytes += memory.map_bytes(values)}
	for _, values in world.scene_source.instances {result.map_bytes += memory.map_bytes(values)}
	result.map_bytes += memory.map_bytes(world.scene_source.components) + memory.map_bytes(world.scene_source.instances)
	result.map_bytes += memory.map_bytes(world.scene_source.entity_ids) + memory.map_bytes(world.scene_source.metadata) + memory.map_bytes(world.scene_source.parents)
	for _, value in world.owned_component_json {result.owned_json_bytes += memory.json_bytes(value.value)}
	for _, arena in world.typed_value_arenas {
		if arena == nil {continue}
		stats := memory.arena_stats(arena)
		result.typed_arenas.block_bytes += stats.block_bytes
		result.typed_arenas.out_band_bytes += stats.out_band_bytes
		result.typed_arenas.bookkeeping_bytes += stats.bookkeeping_bytes + size_of(mem.Dynamic_Arena)
		result.typed_arenas.unknown_out_band_allocations += stats.unknown_out_band_allocations
	}
	for _, state in world.static_meshes {
		result.static_mesh_bytes += u64(cap(state.data.vertices)*size_of(geometry.Vertex) + cap(state.data.indices)*size_of(u32))
	}
	result.hierarchy_bytes = u64(cap(world.roots)*size_of(Entity))
	for _, children in world.children_by_parent {result.hierarchy_bytes += u64(cap(children)*size_of(Entity))}
	return result
}
