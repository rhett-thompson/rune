package ecs

import "core:encoding/json"
import "core:math"
import b2 "vendor:box2d"

// RigidBody2D is Rune-owned data mapped to a Box2D body by the runtime.
// Colliders without a body are static by default.
RigidBody2D :: struct {
	velocity:      [2]f32,
	gravity_scale: f32,
	body_type:     string,
	grounded:      bool,
}

BoxCollider2D :: struct {
	one_way: bool,
	is_sensor: bool,
	size: [2]f32,
	offset: [2]f32,
}
CircleCollider2D :: struct {
	is_sensor: bool,
	radius: f32,
	offset: [2]f32,
}

Physics2D_Fixed_Delta: f32 : 1.0 / 60.0
Physics2D_Gravity: f32 : 1200

rigid_body_2d_from_json :: proc(data: json.Value) -> (RigidBody2D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := RigidBody2D {
		gravity_scale = 1,
		body_type     = "dynamic",
	}
	if value, found := object["velocity"];
	   found && !read_vector2(value, &result.velocity) {return {}, false}
	if value, found := object["gravity_scale"];
	   found {result.gravity_scale, ok = read_number(value); if !ok || result.gravity_scale < 0 {return {}, false}}
	if value, found := object["type"]; found {
		result.body_type, ok = value.(json.String)
		if !ok ||
		   (result.body_type != "dynamic" &&
				   result.body_type != "kinematic" &&
				   result.body_type != "static") {return {}, false}
	}
	return result, component_value_valid(result)
}

box_collider_2d_from_json :: proc(data: json.Value) -> (BoxCollider2D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := BoxCollider2D {
		size = {16, 16},
	}
	if value, found := object["one_way"]; found {result.one_way, ok = value.(json.Boolean); if !ok {return {}, false}}
	if value, found := object["size"];
	   found && !read_vector2(value, &result.size) {return {}, false}
	if value, found := object["offset"]; found && !read_vector2(value, &result.offset) {return {}, false}
	if value, found := object["is_sensor"]; found {
		result.is_sensor, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	return result, component_value_valid(result)
}

circle_collider_2d_from_json :: proc(data: json.Value) -> (CircleCollider2D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := CircleCollider2D {
		radius = 8,
	}
	if value, found := object["radius"];
	   found {result.radius, ok = read_number(value); if !ok || result.radius <= 0 {return {}, false}}
	if value, found := object["offset"]; found && !read_vector2(value, &result.offset) {return {}, false}
	if value, found := object["is_sensor"]; found {
		result.is_sensor, ok = value.(json.Boolean)
		if !ok {return {}, false}
	}
	return result, component_value_valid(result)
}

physics_2d_update :: proc(world: ^World, dt: f32) {
	physics_begin_update(&world.physics_2d)
	if dt <= 0 ||
	   (len(world.rigid_bodies_2d) == 0 &&
			   len(world.box_colliders_2d) == 0 &&
			   len(world.circle_colliders_2d) == 0 &&
			   len(world.capsule_colliders_2d) == 0 &&
			   len(world.polygon_colliders_2d) == 0 &&
			   len(world.segment_colliders_2d) == 0) {return}
	ensure_box2d_world(world)
	world.physics_2d_accumulator += dt
	steps := 0
	for world.physics_2d_accumulator >= Physics2D_Fixed_Delta && steps < 8 {
		sync_bodies_to_box2d(world)
		character_controllers_2d_before_step(world, Physics2D_Fixed_Delta)
		one_way_prepare_2d(world)
		callback := One_Way_Callback_2D{caller_context=context,world=world}
		if len(world.one_way_shapes_2d) > 0 {b2.World_SetPreSolveCallback(world.box2d_world,one_way_pre_solve_2d,&callback)}
		b2.World_Step(world.box2d_world, Physics2D_Fixed_Delta, 4)
		b2.World_SetPreSolveCallback(world.box2d_world,nil,nil)
		one_way_finish_2d(world)
		collect_box2d_events(world)
		sync_bodies_from_box2d(world)
		character_controllers_2d_after_step(world,Physics2D_Fixed_Delta)
		world.physics_2d_accumulator -= Physics2D_Fixed_Delta
		steps += 1
	}
	if steps == 8 {world.physics_2d_accumulator = 0}
}

// physics_2d_shutdown releases the native Box2D objects. Engine scene reloads
// call this before replacing a World; standalone callers should do the same.
physics_2d_shutdown :: proc(world: ^World) {
	clear(&world.one_way_shapes_2d)
	clear(&world.one_way_contacts_2d)
	for entity in world.character_controller_states_2d {character_controller_2d_reset_state(world,entity)}
	physics_state_reset(&world.physics_2d)
	for _, native in world.box2d_bodies {if b2.Body_IsValid(native) {b2.DestroyBody(native)}}
	delete(world.box2d_bodies)
	world.box2d_bodies = make(map[Entity]b2.BodyId)
	if !b2.IS_NULL(world.box2d_world) &&
	   b2.World_IsValid(
		   world.box2d_world,
	   ) {b2.DestroyWorld(world.box2d_world); world.box2d_world = {}}
	world.physics_2d_accumulator = 0
}

physics_2d_remove_entity :: proc(world: ^World, entity: Entity) {
	character_controllers_2d_forget_support(world,entity)
	character_controller_2d_reset_state(world,entity)
	world.physics_2d.needs_sync = true
	if native, found := world.box2d_bodies[entity]; found {
		physics_forget_entity(&world.physics_2d, entity)
		if b2.Body_IsValid(native) {b2.DestroyBody(native)}
		delete_key(&world.box2d_bodies, entity)
	}
}

ensure_box2d_world :: proc(world: ^World) {
	if !b2.IS_NULL(world.box2d_world) {return}
	def := b2.DefaultWorldDef()
	def.gravity = {0, Physics2D_Gravity}
	world.box2d_world = b2.CreateWorld(def)
}

physics_2d_transform_edited :: proc(world: ^World, entity: Entity, previous, value: Transform) {
	if previous.scale != value.scale {
		physics_2d_remove_entity(world, entity)
		return
	}
	if native, found := world.box2d_bodies[entity]; found && b2.Body_IsValid(native) {
		if previous.position != value.position {
			character_controllers_2d_forget_support(world,entity)
			character_controller_2d_reset_state(world,entity)
			b2.Body_SetTransform(native, {value.position[0], value.position[1]}, b2.Body_GetRotation(native))
			b2.Body_SetAwake(native, true)
		}
	}
}

physics_2d_body_edited :: proc(world: ^World, entity: Entity, previous, value: RigidBody2D) {
	native, found := world.box2d_bodies[entity]
	if !found || !b2.Body_IsValid(native) {
		world.physics_2d.needs_sync = true
		return
	}
	type_changed := previous.body_type != value.body_type
	if type_changed {
		character_controllers_2d_forget_support(world,entity)
		b2.Body_SetType(native, box2d_body_type(value.body_type))
	}
	if previous.gravity_scale != value.gravity_scale {b2.Body_SetGravityScale(native, value.gravity_scale)}
	if type_changed || previous.velocity != value.velocity {b2.Body_SetLinearVelocity(native, {value.velocity[0], value.velocity[1]})}
	if previous != value {b2.Body_SetAwake(native, true)}
}

sync_bodies_to_box2d :: proc(world: ^World, apply_velocities := true) {
	defer world.physics_2d.needs_sync = false
	for entity, body in world.rigid_bodies_2d {
		if !is_enabled(world, entity) {continue}
		if _, found := world.box2d_bodies[entity]; found {continue}
		create_box2d_body(world, entity, body)
	}
	for entity in world.box_colliders_2d {
		if !is_enabled(world, entity) {continue}
		if _, exists := world.box2d_bodies[entity]; exists {continue}
		if _, found := world.rigid_bodies_2d[entity]; !found {create_box2d_static(world, entity)}
	}
	for entity in world.circle_colliders_2d {
		if !is_enabled(world, entity) {continue}
		if _, exists := world.box2d_bodies[entity]; exists {continue}
		if _, found := world.rigid_bodies_2d[entity]; !found {create_circle2d_static(world, entity)}
	}
	for entity in world.capsule_colliders_2d {
		if !is_enabled(world, entity) {continue}
		if _, exists := world.box2d_bodies[entity]; exists {continue}
		if _, found := world.rigid_bodies_2d[entity]; !found {create_box2d_static(world, entity)}
	}
	for entity in world.polygon_colliders_2d {
		if !is_enabled(world, entity) {continue}
		if _, exists := world.box2d_bodies[entity]; exists {continue}
		if _, found := world.rigid_bodies_2d[entity]; !found {create_box2d_static(world, entity)}
	}
	for entity in world.segment_colliders_2d {
		if !is_enabled(world, entity) {continue}
		if _, exists := world.box2d_bodies[entity]; exists {continue}
		if _, found := world.rigid_bodies_2d[entity]; !found {create_box2d_static(world, entity)}
	}
	if apply_velocities {
		for entity, body in world.rigid_bodies_2d {
			if !is_enabled(world, entity) {continue}
			native, found := world.box2d_bodies[entity]
			if found {b2.Body_SetLinearVelocity(native, {body.velocity[0], body.velocity[1]})}
		}
	}
}


// Every collider on an entity belongs to the same native body. Independent
// offsets allow, for example, a solid body and a displaced sensor together.
create_box2d_body :: proc(world: ^World, entity: Entity, body: RigidBody2D) {
	transform, found := get_transform(world, entity)
	if !found {return}
	box, has_box := world.box_colliders_2d[entity]
	circle, has_circle := world.circle_colliders_2d[entity]
	capsule, has_capsule := world.capsule_colliders_2d[entity]
	polygon, has_polygon := world.polygon_colliders_2d[entity]
	segment, has_segment := world.segment_colliders_2d[entity]
	if !has_box && !has_circle && !has_capsule && !has_polygon && !has_segment {return}
	mask, _ := entity_layer_mask(world, entity)
	native := create_box2d_body_id(world, body, transform.position[0], transform.position[1])
	world.box2d_bodies[entity] = native
	if has_box {
		create_box2d_box_shape(world, entity, native, box.is_sensor,
			box.size[0] * math.abs(transform.scale[0]) * 0.5,
			box.size[1] * math.abs(transform.scale[1]) * 0.5,
			mask, collider_offset_2d(transform, box.offset))
	}
	if has_circle {
		create_box2d_circle_shape(world, entity, native, circle.is_sensor,
			circle.radius * collider_radius_scale_2d(transform), mask,
			collider_offset_2d(transform, circle.offset))
	}
	local_transform := transform
	local_transform.position = {}
	if has_polygon {create_box2d_polygon_shape(world, entity, native, polygon, local_transform, mask)}
	if has_segment {create_box2d_segment_shape(world, entity, native, segment, local_transform, mask)}
	if has_capsule {
		// Build in body-local coordinates to avoid subtracting large world positions.
		a, b, radius := capsule_collider_2d_geometry(capsule, local_transform)
		create_box2d_capsule_shape(world, entity, native, capsule.is_sensor, a, b, radius, mask)
	}
}

create_box2d_static :: proc(world: ^World, entity: Entity) {
	create_box2d_body(world, entity, RigidBody2D{gravity_scale = 0, body_type = "static"})
}

create_circle2d_static :: proc(world: ^World, entity: Entity) {
	create_box2d_static(world, entity)
}

sync_bodies_from_box2d :: proc(world: ^World) {
	for entity, &body in world.rigid_bodies_2d {
		if !is_enabled(world, entity) {continue}
		native, found := world.box2d_bodies[entity]
		if !found {continue}
		transform, has_transform := get_transform(world, entity)
		if !has_transform {continue}
		position := b2.Body_GetPosition(native)
		velocity := b2.Body_GetLinearVelocity(native)
		transform.position[0] = position.x
		transform.position[1] = position.y
		body.velocity[0] = velocity.x
		body.velocity[1] = velocity.y
		body.grounded = box2d_is_grounded(world,native)
		if world.transforms[entity] != transform {record_component_change(world, entity, "Transform", .Changed)}
		if world.rigid_bodies_2d[entity] != body {record_component_change(world, entity, "RigidBody2D", .Changed)}
		world.transforms[entity] = transform
		world.rigid_bodies_2d[entity] = body
	}
}

create_box2d_body_id :: proc(world: ^World, body: RigidBody2D, x, y: f32) -> b2.BodyId {
	def := b2.DefaultBodyDef()
	def.type = box2d_body_type(body.body_type)
	def.position = {x, y}
	def.linearVelocity = {body.velocity[0], body.velocity[1]}
	def.gravityScale = body.gravity_scale
	def.fixedRotation = true
	return b2.CreateBody(world.box2d_world, def)
}

create_box2d_shape_def :: proc(layer_mask: u64, sensor: bool) -> b2.ShapeDef {
	def := b2.DefaultShapeDef()
	def.density = 1
	def.isSensor = sensor
	def.enableSensorEvents = true
	def.enableContactEvents = true
	def.enablePreSolveEvents = !sensor
	def.material.friction = 0.6
	def.filter.categoryBits = layer_mask
	def.filter.maskBits = layer_mask
	return def
}

create_box2d_box_shape :: proc(world: ^World, entity: Entity, body: b2.BodyId, sensor: bool, half_width, half_height: f32, layer_mask: u64, offset: [2]f32 = {}) {
	if !finite_nonnegative(half_width) || !finite_nonnegative(half_height) || half_width == 0 || half_height == 0 || !physics_query_vector_valid(offset) {return}
	def := create_box2d_shape_def(layer_mask, sensor)
	shape := b2.MakeOffsetBox(half_width, half_height, {offset[0], offset[1]}, {c = 1, s = 0})
	id := b2.CreatePolygonShape(body, def, &shape)
	world.physics_2d.shapes[transmute(u64)id] = {entity, "BoxCollider2D"}
}

create_box2d_circle_shape :: proc(world: ^World, entity: Entity, body: b2.BodyId, sensor: bool, radius: f32, layer_mask: u64, offset: [2]f32 = {}, component := "CircleCollider2D") {
	if !finite_nonnegative(radius) || radius == 0 || !physics_query_vector_valid(offset) {return}
	def := create_box2d_shape_def(layer_mask, sensor)
	shape := b2.Circle {
		center = {offset[0], offset[1]},
		radius = radius,
	}
	id := b2.CreateCircleShape(body, def, &shape)
	world.physics_2d.shapes[transmute(u64)id] = {entity, component}
}

box2d_is_grounded :: proc(world: ^World, body: b2.BodyId) -> bool {
	contacts: [16]b2.ContactData
	for contact in b2.Body_GetContactData(body, contacts[:]) {
		if contact.manifold.pointCount == 0 || !one_way_contact_2d(world,contact.shapeIdA,contact.shapeIdB,contact.manifold.normal) {continue}
		if b2.ID_EQUALS(b2.Shape_GetBody(contact.shapeIdA), body) {
			if contact.manifold.normal.y > 0.5 {return true}
		} else if contact.manifold.normal.y < -0.5 {
			return true
		}
	}
	return false
}

box2d_body_type :: proc(body_type: string) -> b2.BodyType {
	if body_type == "dynamic" {return .dynamicBody}
	if body_type == "kinematic" {return .kinematicBody}
	return .staticBody
}

create_box2d_capsule_shape :: proc(world: ^World, entity: Entity, body: b2.BodyId, sensor: bool, a, b: [2]f32, radius: f32, layer_mask: u64) {
	if !finite_nonnegative(radius) || radius == 0 || !physics_query_vector_valid(a) || !physics_query_vector_valid(b) {return}
	// Equal endpoints form a circle. Keep the Rune component identity in hits
	// and events even when the backend uses its circle representation.
	if a == b {
		create_box2d_circle_shape(world, entity, body, sensor, radius, layer_mask, a, "CapsuleCollider2D")
		return
	}
	def := create_box2d_shape_def(layer_mask, sensor)
	shape := b2.Capsule{center1 = {a[0], a[1]}, center2 = {b[0], b[1]}, radius = radius}
	id := b2.CreateCapsuleShape(body, def, &shape)
	world.physics_2d.shapes[transmute(u64)id] = {entity, "CapsuleCollider2D"}
}

create_box2d_polygon_shape :: proc(world: ^World, entity: Entity, body: b2.BodyId, collider: PolygonCollider2D, transform: Transform, layer_mask: u64) {
	points: [b2.MAX_POLYGON_VERTICES][2]f32
	if len(collider.vertices) < 3 || len(collider.vertices) > len(points) {return}
	for point, i in collider.vertices {points[i] = collider_point_2d(transform, point, collider.offset)}
	hull, ok := polygon_hull_2d(points[:len(collider.vertices)])
	if !ok {return} // Zero/tiny scales can collapse otherwise valid geometry.
	shape := b2.MakePolygon(hull, 0)
	def := create_box2d_shape_def(layer_mask, collider.is_sensor)
	id := b2.CreatePolygonShape(body, def, &shape)
	world.physics_2d.shapes[transmute(u64)id] = {entity, "PolygonCollider2D"}
}

create_box2d_segment_shape :: proc(world: ^World, entity: Entity, body: b2.BodyId, collider: SegmentCollider2D, transform: Transform, layer_mask: u64) {
	a := collider_point_2d(transform, collider.start, collider.offset)
	b := collider_point_2d(transform, collider.end, collider.offset)
	if !segment_points_valid_2d(a, b) {return}
	shape := b2.Segment{point1 = {a[0], a[1]}, point2 = {b[0], b[1]}}
	def := create_box2d_shape_def(layer_mask, collider.is_sensor)
	id := b2.CreateSegmentShape(body, def, &shape)
	world.physics_2d.shapes[transmute(u64)id] = {entity, "SegmentCollider2D"}
}
