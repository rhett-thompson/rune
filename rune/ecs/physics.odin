package ecs

import "core:encoding/json"

// BoxCollider is an axis-aligned collision volume. Static colliders are the
// first supported environment geometry; their size is multiplied by Transform
// scale so a unit collider matches the engine's cube debug primitive.
BoxCollider :: struct {
	size:               [3]f32,
	is_static:          bool,
	friction:           f32,
	restitution:        f32,
	rolling_resistance: f32,
}

// SphereCollider is a sphere-shaped collision volume. Its radius is scaled by
// the largest Transform scale axis so non-uniformly scaled entities remain
// conservative for collision purposes.
SphereCollider :: struct {
	radius:             f32,
	is_static:          bool,
	friction:           f32,
	restitution:        f32,
	rolling_resistance: f32,
}

// CharacterController is a simple upright player volume. Transform position
// remains the camera eye position; eye_height measures from the feet to it.
CharacterController :: struct {
	radius:            f32,
	height:            f32,
	eye_height:        f32,
	gravity:           f32,
	jump_speed:        f32,
	vertical_velocity: f32,
	grounded:          bool,
}

box_collider_from_json :: proc(data: json.Value) -> (BoxCollider, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := BoxCollider {
		size      = {1, 1, 1},
		is_static = true,
		friction  = 0.6,
	}
	if value, found := object["size"];
	   found && !read_vector3(value, &result.size) {return {}, false}
	for size in result.size {if size <= 0 {return {}, false}}
	if value, found := object["is_static"]; found {
		result.is_static, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	if !physics_material_fields_from_json(
		object,
		&result.friction,
		&result.restitution,
		&result.rolling_resistance,
	) {return {}, false}
	return result, true
}

sphere_collider_from_json :: proc(data: json.Value) -> (SphereCollider, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := SphereCollider {
		radius    = 0.5,
		is_static = true,
		friction  = 0.6,
	}
	if value, found := object["radius"]; found {
		result.radius, ok = read_number(value)
		if !ok || result.radius <= 0 {return {}, false}
	}
	if value, found := object["is_static"]; found {
		result.is_static, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	if !physics_material_fields_from_json(
		object,
		&result.friction,
		&result.restitution,
		&result.rolling_resistance,
	) {return {}, false}
	return result, true
}

physics_material_fields_from_json :: proc(
	object: json.Object,
	friction, restitution, rolling_resistance: ^f32,
) -> bool {
	if value, found := object["friction"]; found {
		parsed, ok := read_number(value)
		if !ok || parsed < 0 {return false}
		friction^ = parsed
	}
	if value, found := object["restitution"]; found {
		parsed, ok := read_number(value)
		if !ok || parsed < 0 {return false}
		restitution^ = parsed
	}
	if value, found := object["rolling_resistance"]; found {
		parsed, ok := read_number(value)
		if !ok || parsed < 0 {return false}
		rolling_resistance^ = parsed
	}
	if value, found := object["physics_material"]; found {
		material, ok := value.(json.Object)
		if !ok {return false}
		if !physics_material_fields_from_json(
			material,
			friction,
			restitution,
			rolling_resistance,
		) {return false}
	}
	return true
}

character_controller_from_json :: proc(data: json.Value) -> (CharacterController, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := CharacterController {
		radius     = 0.35,
		height     = 1.8,
		eye_height = 1.6,
		gravity    = 24,
		jump_speed = 8,
	}
	if value, found := object["radius"];
	   found {result.radius, ok = read_number(value); if !ok || result.radius <= 0 {return {}, false}}
	if value, found := object["height"];
	   found {result.height, ok = read_number(value); if !ok || result.height <= 0 {return {}, false}}
	if value, found := object["eye_height"];
	   found {result.eye_height, ok = read_number(value); if !ok || result.eye_height <= 0 {return {}, false}}
	if value, found := object["gravity"];
	   found {result.gravity, ok = read_number(value); if !ok || result.gravity <= 0 {return {}, false}}
	if value, found := object["jump_speed"];
	   found {result.jump_speed, ok = read_number(value); if !ok || result.jump_speed <= 0 {return {}, false}}
	if result.eye_height > result.height {return {}, false}
	return result, true
}

// move_character applies horizontal movement, gravity, jumping, and collision
// against static BoxCollider and SphereCollider entities sharing at least one
// layer bit.
move_character :: proc(
	world: ^World,
	entity: Entity,
	horizontal: [2]f32,
	jump: bool,
	dt: f32,
) -> bool {
	transform, has_transform := get_transform(world, entity)
	controller, has_controller := get_character_controller(world, entity)
	if !has_transform || !has_controller {return false}

	if jump && controller.grounded {
		controller.vertical_velocity = controller.jump_speed
		controller.grounded = false
	}
	controller.vertical_velocity -= controller.gravity * dt
	position := transform.position
	position[0] = move_character_axis(world, entity, controller, position, 0, horizontal[0])
	position[2] = move_character_axis(world, entity, controller, position, 2, horizontal[1])

	vertical_delta := controller.vertical_velocity * dt
	vertical_position := move_character_axis(
		world,
		entity,
		controller,
		position,
		1,
		vertical_delta,
	)
	controller.grounded = false
	if vertical_position != position[1] {
		position[1] = vertical_position
	} else if vertical_delta < 0 {
		controller.vertical_velocity = 0
		controller.grounded = true
	} else if vertical_delta > 0 {
		controller.vertical_velocity = 0
	}

	transform.position = position
	set_transform(world, entity, transform)
	set_character_controller(world, entity, controller)
	return true
}

move_character_axis :: proc(
	world: ^World,
	entity: Entity,
	controller: CharacterController,
	position: [3]f32,
	axis: int,
	delta: f32,
) -> f32 {
	if delta == 0 {return position[axis]}
	candidate := position
	candidate[axis] += delta
	// Typed collider maps are the query index. Iterating them directly avoids
	// allocating an entity slice for each resolved movement axis.
	for collider_entity, collider in world.box_colliders {
		if collider_entity == entity ||
		   !collides_by_layer(world, entity, collider_entity) {continue}
		if !collider.is_static {continue}
		if !character_intersects_box(
			world,
			controller,
			candidate,
			collider_entity,
			collider,
		) {continue}
		if axis != 1 {return position[axis]}
		box_min, box_max, bounds_ok := box_bounds(world, collider_entity, collider)
		if !bounds_ok {continue}
		if delta < 0 {return box_max[1] + controller.eye_height}
		return box_min[1] - (controller.height - controller.eye_height)
	}
	for collider_entity, collider in world.sphere_colliders {
		if collider_entity == entity ||
		   !collides_by_layer(world, entity, collider_entity) {continue}
		if !collider.is_static ||
		   !character_intersects_sphere(
				   world,
				   controller,
				   candidate,
				   collider_entity,
				   collider,
			   ) {continue}
		if axis != 1 {return position[axis]}
		center, radius, bounds_ok := sphere_bounds(world, collider_entity, collider)
		if !bounds_ok {continue}
		if delta < 0 {return center[1] + radius + controller.eye_height}
		return center[1] - radius - (controller.height - controller.eye_height)
	}
	return candidate[axis]
}

collides_by_layer :: proc(world: ^World, first, second: Entity) -> bool {
	first_mask, first_found := entity_layer_mask(world, first)
	second_mask, second_found := entity_layer_mask(world, second)
	return first_found && second_found && (first_mask & second_mask) != 0
}

character_intersects_box :: proc(
	world: ^World,
	controller: CharacterController,
	eye_position: [3]f32,
	collider_entity: Entity,
	collider: BoxCollider,
) -> bool {
	box_min, box_max, bounds_ok := box_bounds(world, collider_entity, collider)
	if !bounds_ok {return false}
	character_min := [3]f32 {
		eye_position[0] - controller.radius,
		eye_position[1] - controller.eye_height,
		eye_position[2] - controller.radius,
	}
	character_max := [3]f32 {
		eye_position[0] + controller.radius,
		eye_position[1] + (controller.height - controller.eye_height),
		eye_position[2] + controller.radius,
	}
	return(
		character_min[0] < box_max[0] &&
		character_max[0] > box_min[0] &&
		character_min[1] < box_max[1] &&
		character_max[1] > box_min[1] &&
		character_min[2] < box_max[2] &&
		character_max[2] > box_min[2] \
	)
}

box_bounds :: proc(
	world: ^World,
	entity: Entity,
	collider: BoxCollider,
) -> (
	[3]f32,
	[3]f32,
	bool,
) {
	transform, found := get_transform(world, entity)
	if !found {return {}, {}, false}
	half_size := [3]f32 {
		collider.size[0] * transform.scale[0] * 0.5,
		collider.size[1] * transform.scale[1] * 0.5,
		collider.size[2] * transform.scale[2] * 0.5,
	}
	return transform.position - half_size, transform.position + half_size, true
}

character_intersects_sphere :: proc(
	world: ^World,
	controller: CharacterController,
	eye_position: [3]f32,
	collider_entity: Entity,
	collider: SphereCollider,
) -> bool {
	center, radius, bounds_ok := sphere_bounds(world, collider_entity, collider)
	if !bounds_ok {return false}
	character_min := [3]f32 {
		eye_position[0] - controller.radius,
		eye_position[1] - controller.eye_height,
		eye_position[2] - controller.radius,
	}
	character_max := [3]f32 {
		eye_position[0] + controller.radius,
		eye_position[1] + (controller.height - controller.eye_height),
		eye_position[2] + controller.radius,
	}
	nearest := [3]f32 {
		clamp_f32(center[0], character_min[0], character_max[0]),
		clamp_f32(center[1], character_min[1], character_max[1]),
		clamp_f32(center[2], character_min[2], character_max[2]),
	}
	difference := center - nearest
	return(
		difference[0] * difference[0] +
			difference[1] * difference[1] +
			difference[2] * difference[2] <
		radius * radius \
	)
}

sphere_bounds :: proc(
	world: ^World,
	entity: Entity,
	collider: SphereCollider,
) -> (
	[3]f32,
	f32,
	bool,
) {
	transform, found := get_transform(world, entity)
	if !found {return {}, 0, false}
	scale := transform.scale[0]
	if transform.scale[1] > scale {scale = transform.scale[1]}
	if transform.scale[2] > scale {scale = transform.scale[2]}
	return transform.position, collider.radius * scale, true
}

clamp_f32 :: proc(value, minimum, maximum: f32) -> f32 {
	if value < minimum {return minimum}
	if value > maximum {return maximum}
	return value
}
