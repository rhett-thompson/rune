package ecs

import "core:encoding/json"
import "core:math"
import "rune:particles"

ParticleEmitter2D :: particles.Emitter2D

default_particle_emitter_2d :: particles.defaults

particle_emitter_2d_from_json :: proc(data: json.Value) -> (ParticleEmitter2D, bool) {
	if !json_shape_matches_type(data, ParticleEmitter2D) {return {}, false}
	object := data.(json.Object)
	for key, value in object {
		if json_value_is_nil(value) {return {}, false}
		if _, is_null := value.(json.Null); is_null {return {}, false}
		if key == "lifetime" || key == "speed" || key == "gravity" {
			vector: [2]f32
			if !read_vector2(value, &vector) {return {}, false}
		}
		if key == "start_color" || key == "end_color" {
			color: Color
			if !read_color(value, &color) {return {}, false}
		}
		if key == "seed" || key == "max_particles" || key == "draw_order" {
			number: f64
			#partial switch v in value {
			case json.Integer: number = f64(v)
			case json.Float: number = v
			case: return {}, false
			}
			minimum, maximum: f64 = 0, 4294967295
			if key == "max_particles" {minimum, maximum = 1, 65536}
			if key == "draw_order" {minimum, maximum = -1000000, 1000000}
			if math.is_nan(number) || number < minimum || number > maximum || math.floor(number) != number {return {}, false}
		}
	}
	result := default_particle_emitter_2d()
	bytes, err := json.marshal(data, allocator = context.temp_allocator)
	if err != nil || json.unmarshal(bytes, &result, allocator = context.temp_allocator) != nil {
		return {}, false
	}
	return result, particles.valid(result)
}

get_particle_emitter_2d :: proc(world: ^World, entity: Entity) -> (ParticleEmitter2D, bool) {
	value, found := world.particle_emitters_2d[entity]
	return value, found
}

set_particle_emitter_2d :: proc(world: ^World, entity: Entity, value: ParticleEmitter2D) -> bool {
	if !has_component_data(world, entity, "ParticleEmitter2D") || !particles.valid(value) {return false}
	owned := value
	owned.texture = retain_scene_string(world, value.texture)
	commit_component_value(world, entity, "ParticleEmitter2D", &world.particle_emitters_2d, owned)
	return true
}

// Explicit bursts work even with emitting=false. Return the actual count;
// saturation drops excess births. Call from start/update/fixed_update systems.
emit_particles_2d :: proc(world: ^World, entity: Entity, count: int) -> int {
	settings, found := world.particle_emitters_2d[entity]
	if !found || count <= 0 {return 0}
	position, rotation, scale := particle_emitter_pose_2d(world, entity)
	state := world.particle_states_2d[entity]
	spawned := particles.emit(&state, settings, count, position, rotation, scale)
	world.particle_states_2d[entity] = state
	return spawned
}

clear_particles_2d :: proc(world: ^World, entity: Entity) -> bool {
	if _, found := world.particle_emitters_2d[entity]; !found {return false}
	state := world.particle_states_2d[entity]
	particles.clear(&state)
	world.particle_states_2d[entity] = state
	return true
}

particle_count_2d :: proc(world: ^World, entity: Entity) -> int {
	return len(world.particle_states_2d[entity].particles)
}

// Engine scene loops call this after game updates. Custom loops call it once
// per simulation tick; rendering only reads particles and cannot advance them.
update_particles_2d :: proc(world: ^World, dt: f32) {
	for entity, settings in world.particle_emitters_2d {
		position, rotation, scale := particle_emitter_pose_2d(world, entity)
		state := world.particle_states_2d[entity]
		particles.update(&state, settings, dt, position, rotation, scale)
		world.particle_states_2d[entity] = state
	}
}

@(private)
remove_particle_state_2d :: proc(world: ^World, entity: Entity) {
	if state, found := world.particle_states_2d[entity]; found {
		particles.destroy(&state)
		delete_key(&world.particle_states_2d, entity)
	}
}

// Match the current 2D renderer's translation/scale hierarchy conventions.
// Rotation changes the emission direction; scale changes particle diameter.
@(private)
particle_emitter_pose_2d :: proc(world: ^World, entity: Entity) -> (position: [2]f32, rotation, scale: f32) {
	scaling := [2]f32{1, 1}
	current := entity
	for current != Entity(0) {
		if transform, found := world.transforms[current]; found {
			local_scale := [2]f32{transform.scale[0], transform.scale[1]}
			position = position * local_scale + {transform.position[0], transform.position[1]}
			scaling *= local_scale
			rotation += transform.rotation[2]
		}
		current = world.parents[current]
	}
	scale = max(math.abs(scaling[0]), math.abs(scaling[1]))
	return
}
