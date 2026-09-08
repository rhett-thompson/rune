package ecs

import "core:math"
import "rune:particles"

// These constraints are shared by JSON readers and typed setters. Keep checks
// on hot gameplay paths scalar: no JSON serialization or scratch allocation.
component_value_valid :: proc(value: $T) -> bool {
	when T == ParticleEmitter2D {
		return particles.valid(value)
	} else when T == Lifetime {
		return finite_nonnegative(value.seconds)
	} else when T == ShapeRenderer2D {
		if value.shape != .rectangle && value.shape != .circle {return false}
		for v in value.size {if !finite_nonnegative(v) || v == 0 {return false}}
		for v in value.origin {if math.is_nan(v) || math.is_inf(v) {return false}}
		return finite_nonnegative(value.radius) && value.radius > 0 &&
		       finite_nonnegative(value.line_width) && value.line_width > 0 &&
		       value.draw_order >= -1000000 && value.draw_order <= 1000000
	} else when T == Transform {
		for v in value.position {if math.is_nan(v) || math.is_inf(v) {return false}}
		for v in value.rotation {if math.is_nan(v) || math.is_inf(v) {return false}}
		for v in value.scale {if math.is_nan(v) || math.is_inf(v) {return false}}
	} else when T == RigidBody2D || T == RigidBody3D {
		if value.body_type != "dynamic" && value.body_type != "kinematic" && value.body_type != "static" {return false}
		if !finite_nonnegative(value.gravity_scale) {return false}
		for v in value.velocity {if math.is_nan(v) || math.is_inf(v) {return false}}
		when T == RigidBody3D {
			for v in value.angular_velocity {if math.is_nan(v) || math.is_inf(v) {return false}}
			return finite_nonnegative(value.linear_damping) && finite_nonnegative(value.angular_damping)
		}
	} else when T == BoxCollider || T == BoxCollider2D {
		for size in value.size {if !(size > 0) || math.is_inf(size) {return false}}
		when T == BoxCollider {
			return finite_nonnegative(value.friction) && finite_nonnegative(value.restitution) && finite_nonnegative(value.rolling_resistance)
		}
	} else when T == SphereCollider || T == CircleCollider2D {
		if !(value.radius > 0) || math.is_inf(value.radius) {return false}
		when T == SphereCollider {
			return finite_nonnegative(value.friction) && finite_nonnegative(value.restitution) && finite_nonnegative(value.rolling_resistance)
		}
	} else when T == ModelAnimator {
		return value.speed != 0 && !math.is_nan(value.speed) && !math.is_inf(value.speed) && finite_nonnegative(value.blend_time)
	} else when T == SpriteAnimator {
		return value.animation != "" && value.clip != "" && value.speed > 0 && !math.is_inf(value.speed)
	} else when T == AudioPlayer {
		if value.bus < .master || value.bus > .ui {return false}
		return value.sound != "" && finite_nonnegative(value.volume) && value.pitch > 0 && !math.is_inf(value.pitch) &&
		       finite_nonnegative(value.random_volume) && finite_nonnegative(value.random_pitch) && value.max_voices >= 1 &&
		       finite_nonnegative(value.min_distance) && value.max_distance >= value.min_distance && !math.is_inf(value.max_distance)
	} else when T == CharacterController {
		return value.radius > 0 && value.height > 0 && value.eye_height > 0 && value.eye_height <= value.height &&
		       value.gravity > 0 && value.jump_speed > 0
	}
	return true
}

finite_nonnegative :: proc(value: f32) -> bool {
	return value >= 0 && !math.is_inf(value)
}

// Call after validation and ownership transfer. All component write paths use
// this boundary so notifications and native/cache updates happen exactly once.
commit_component_value :: proc(
	world: ^World,
	entity: Entity,
	name: string,
	storage: ^map[Entity]$T,
	value: T,
	kind: Component_Change_Kind = .Changed,
) {
	previous, existed := storage^[entity]
	when T == Lifetime {delete_key(&world.lifetime_elapsed, entity)}
	when T == ParticleEmitter2D {
		// Capacity/seed changes restart the bounded pool. Appearance and rate
		// edits preserve existing particles and apply to subsequent births.
		if !existed || previous.max_particles != value.max_particles || previous.seed != value.seed {
			remove_particle_state_2d(world, entity)
		}
	} else when T == Transform {
		physics_2d_transform_edited(world, entity, previous, value)
		physics_3d_transform_edited(world, entity, previous, value)
	} else when T == RigidBody2D {
		physics_2d_body_edited(world, entity, previous, value)
	} else when T == RigidBody3D {
		physics_3d_body_edited(world, entity, previous, value)
	} else when T == BoxCollider2D || T == CircleCollider2D {
		if !existed || previous != value {physics_2d_remove_entity(world, entity)}
	} else when T == BoxCollider || T == SphereCollider {
		if !existed || previous != value {physics_3d_remove_entity(world, entity)}
	} else when T == ModelAnimator {
		if !existed || previous.clip != value.clip || previous.autoplay != value.autoplay {
			world.model_animation_states[entity] = {}
		}
	} else when T == SpriteAnimator {
		if !existed || previous.animation != value.animation ||
		   previous.clip != value.clip || previous.autoplay != value.autoplay {
			world.sprite_animation_states[entity] = {}
		}
	}
	storage^[entity] = value
	record_component_change(world, entity, name, kind)
}

// Authored settings replace configuration, while the simulation owns these
// fields. Typed gameplay setters can still update them explicitly.
preserve_simulation_state :: proc(world: ^World, entity: Entity, value: $T) -> T {
	result := value
	when T == CharacterController {
		if previous, found := world.character_controllers[entity]; found {
			result.grounded = previous.grounded
			result.vertical_velocity = previous.vertical_velocity
		}
	} else when T == RigidBody2D {
		if previous, found := world.rigid_bodies_2d[entity]; found {
			result.grounded = previous.grounded
		}
	}
	return result
}

invalidate_component_physics :: proc(world: ^World, entity: Entity, name: string) {
	switch name {
	case "Transform":
		physics_2d_remove_entity(world, entity)
		physics_3d_remove_entity(world, entity)
	case "RigidBody2D", "BoxCollider2D", "CircleCollider2D":
		physics_2d_remove_entity(world, entity)
	case "RigidBody3D", "BoxCollider", "SphereCollider":
		physics_3d_remove_entity(world, entity)
	}
}
