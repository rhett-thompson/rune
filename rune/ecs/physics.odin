package ecs

import "core:encoding/json"

// BoxCollider's primary box and optional local boxes share one physical body.
// Dimensions and offsets are multiplied by Transform scale, then rotated by
// its orientation. add/set copy additional_boxes; getters borrow that storage.
BoxCollider_Box :: struct {
	offset, size: [3]f32,
}
MAX_ADDITIONAL_COLLIDER_BOXES :: 32

BoxCollider :: struct {
	is_sensor: bool,
	size:               [3]f32,
	is_static:          bool,
	friction:           f32,
	restitution:        f32,
	rolling_resistance: f32,
	additional_boxes: []BoxCollider_Box,
}

// SphereCollider is a sphere-shaped collision volume. Its radius is scaled by
// the largest Transform scale axis so non-uniformly scaled entities remain
// conservative for collision purposes.
SphereCollider :: struct {
	is_sensor: bool,
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
	if value, found := object["is_sensor"]; found {
		result.is_sensor, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	if value, found := object["additional_boxes"]; found {
		array, valid := value.(json.Array)
		_,null:=value.(json.Null)
		if (!valid && !null) || len(array)>MAX_ADDITIONAL_COLLIDER_BOXES {return {},false}
		result.additional_boxes=make([]BoxCollider_Box,len(array),context.temp_allocator)
		for entry,i in array {
			box, valid := entry.(json.Object)
			if !valid {return {},false}
			result.additional_boxes[i].size={1,1,1}
			for key,field in box {
				switch key {
				case "offset": if !read_vector3(field,&result.additional_boxes[i].offset) {return {},false}
				case "size": if !read_vector3(field,&result.additional_boxes[i].size) {return {},false}
				case: return {},false
				}
			}
		}
	}
	return result, component_value_valid(result)
}

box_colliders_equal :: proc(a,b:BoxCollider) -> bool {
	if a.size!=b.size || a.is_static!=b.is_static || a.is_sensor!=b.is_sensor ||
	   a.friction!=b.friction || a.restitution!=b.restitution || a.rolling_resistance!=b.rolling_resistance ||
	   len(a.additional_boxes)!=len(b.additional_boxes) {return false}
	for box,i in a.additional_boxes {if box!=b.additional_boxes[i] {return false}}
	return true
}

// Returns one of the component's local boxes, including its centered primary
// box at index zero. Useful to keep baking/debug geometry aligned with physics.
box_collider_box :: proc(collider:BoxCollider,index:int) -> BoxCollider_Box {
	if index==0 {return {size=collider.size}}
	return collider.additional_boxes[index-1]
}

box_collider_box_transform :: proc(transform:Transform,box:BoxCollider_Box) -> Transform {
	return compose_transform_3d(transform,Transform{position=box.offset,scale={1,1,1}})
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
	if value, found := object["is_sensor"]; found {
		result.is_sensor, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	return result, component_value_valid(result)
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
	return result, component_value_valid(result)
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
	if !has_transform || !has_controller || !is_enabled(world, entity) {return false}

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
		if !collider.is_static || collider.is_sensor {continue}
		for index in 0..=len(collider.additional_boxes) {
			box_min,box_max,bounds_ok:=box_part_bounds(world,collider_entity,box_collider_box(collider,index))
			if !bounds_ok || !character_intersects_box_bounds(controller,candidate,box_min,box_max) {continue}
			if axis!=1 {return position[axis]}
			if delta<0 {return box_max[1]+controller.eye_height}
			return box_min[1]-(controller.height-controller.eye_height)
		}
	}
	for collider_entity, collider in world.sphere_colliders {
		if collider_entity == entity ||
		   !collides_by_layer(world, entity, collider_entity) {continue}
		if !collider.is_static || collider.is_sensor ||
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
	return first_found && second_found && is_enabled(world, first) && is_enabled(world, second) && (first_mask & second_mask) != 0
}

character_intersects_box :: proc(
	world: ^World,
	controller: CharacterController,
	eye_position: [3]f32,
	collider_entity: Entity,
	collider: BoxCollider,
) -> bool {
	for index in 0..=len(collider.additional_boxes) {
		box_min,box_max,bounds_ok:=box_part_bounds(world,collider_entity,box_collider_box(collider,index))
		if bounds_ok && character_intersects_box_bounds(controller,eye_position,box_min,box_max) {return true}
	}
	return false
}

character_intersects_box_bounds :: proc(controller:CharacterController,eye_position,box_min,box_max:[3]f32) -> bool {
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
	low,high,ok:=box_part_bounds(world,entity,{size=collider.size})
	if !ok {return {},{},false}
	for part in collider.additional_boxes {
		part_low,part_high,_:=box_part_bounds(world,entity,part)
		for axis in 0..<3 {low[axis]=min(low[axis],part_low[axis]); high[axis]=max(high[axis],part_high[axis])}
	}
	return low,high,true
}

box_part_bounds :: proc(world:^World,entity:Entity,part:BoxCollider_Box) -> ([3]f32,[3]f32,bool) {
	transform, found := get_transform(world,entity)
	if !found {return {}, {}, false}
	// Preserve the legacy mover's axis-aligned behavior for every local box.
	center:=transform.position+part.offset*transform.scale
	half_size := [3]f32 {
		part.size[0] * abs(transform.scale[0]) * 0.5,
		part.size[1] * abs(transform.scale[1]) * 0.5,
		part.size[2] * abs(transform.scale[2]) * 0.5,
	}
	return center-half_size,center+half_size,true
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
