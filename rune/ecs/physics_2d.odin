package ecs

import "core:encoding/json"
import b2 "vendor:box2d"

// RigidBody2D is Rune-owned data mapped to a Box2D body by the runtime.
// Colliders without a body are static by default.
RigidBody2D :: struct {
	velocity:      [2]f32,
	gravity_scale: f32,
	body_type:     string,
	grounded:      bool,
}

BoxCollider2D :: struct { size: [2]f32 }
CircleCollider2D :: struct { radius: f32 }

Physics2D_Fixed_Delta : f32 : 1.0 / 60.0
Physics2D_Gravity     : f32 : 1200

rigid_body_2d_from_json :: proc(data: json.Value) -> (RigidBody2D, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := RigidBody2D{gravity_scale = 1, body_type = "dynamic"}
	if value, found := object["velocity"]; found && !read_vector2(value, &result.velocity) { return {}, false }
	if value, found := object["gravity_scale"]; found { result.gravity_scale, ok = read_number(value); if !ok || result.gravity_scale < 0 { return {}, false } }
	if value, found := object["type"]; found {
		result.body_type, ok = value.(json.String)
		if !ok || (result.body_type != "dynamic" && result.body_type != "kinematic" && result.body_type != "static") { return {}, false }
	}
	return result, true
}

box_collider_2d_from_json :: proc(data: json.Value) -> (BoxCollider2D, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := BoxCollider2D{size = {16, 16}}
	if value, found := object["size"]; found && !read_vector2(value, &result.size) { return {}, false }
	return result, result.size[0] > 0 && result.size[1] > 0
}

circle_collider_2d_from_json :: proc(data: json.Value) -> (CircleCollider2D, bool) {
	object, ok := data.(json.Object)
	if !ok { return {}, false }
	result := CircleCollider2D{radius = 8}
	if value, found := object["radius"]; found { result.radius, ok = read_number(value); if !ok || result.radius <= 0 { return {}, false } }
	return result, true
}

physics_2d_update :: proc(world: ^World, dt: f32) {
	if dt <= 0 || (len(world.rigid_bodies_2d) == 0 && len(world.box_colliders_2d) == 0 && len(world.circle_colliders_2d) == 0) { return }
	ensure_box2d_world(world)
	world.physics_2d_accumulator += dt
	steps := 0
	for world.physics_2d_accumulator >= Physics2D_Fixed_Delta && steps < 8 {
		sync_bodies_to_box2d(world)
		b2.World_Step(world.box2d_world, Physics2D_Fixed_Delta, 4)
		sync_bodies_from_box2d(world)
		world.physics_2d_accumulator -= Physics2D_Fixed_Delta
		steps += 1
	}
	if steps == 8 { world.physics_2d_accumulator = 0 }
}

// physics_2d_shutdown releases the native Box2D objects. Engine scene reloads
// call this before replacing a World; standalone callers should do the same.
physics_2d_shutdown :: proc(world: ^World) {
	for _, native in world.box2d_bodies { if b2.Body_IsValid(native) { b2.DestroyBody(native) } }
	delete(world.box2d_bodies)
	world.box2d_bodies = make(map[Entity]b2.BodyId)
	if !b2.IS_NULL(world.box2d_world) && b2.World_IsValid(world.box2d_world) { b2.DestroyWorld(world.box2d_world); world.box2d_world = {} }
	world.physics_2d_accumulator = 0
}

physics_2d_remove_entity :: proc(world: ^World, entity: Entity) {
	if native, found := world.box2d_bodies[entity]; found {
		if b2.Body_IsValid(native) { b2.DestroyBody(native) }
		delete_key(&world.box2d_bodies, entity)
	}
}

ensure_box2d_world :: proc(world: ^World) {
	if !b2.IS_NULL(world.box2d_world) { return }
	def := b2.DefaultWorldDef()
	def.gravity = {0, Physics2D_Gravity}
	world.box2d_world = b2.CreateWorld(def)
}

sync_bodies_to_box2d :: proc(world: ^World) {
	for entity, body in world.rigid_bodies_2d {
		if _, found := world.box2d_bodies[entity]; found { continue }
		create_box2d_body(world, entity, body)
	}
	for entity in world.box_colliders_2d { if _, found := world.rigid_bodies_2d[entity]; !found { create_box2d_static(world, entity) } }
	for entity in world.circle_colliders_2d { if _, found := world.rigid_bodies_2d[entity]; !found { create_circle2d_static(world, entity) } }
	for entity, body in world.rigid_bodies_2d {
		native, found := world.box2d_bodies[entity]
		if found { b2.Body_SetLinearVelocity(native, {body.velocity[0], body.velocity[1]}) }
	}
}

create_box2d_body :: proc(world: ^World, entity: Entity, body: RigidBody2D) {
	transform, found := get_transform(world, entity)
	if !found { return }
	mask, _ := entity_layer_mask(world, entity)
	if collider, has_collider := world.box_colliders_2d[entity]; has_collider {
		native := create_box2d_body_id(world, body, transform.position[0], transform.position[1])
		create_box2d_box_shape(native, collider.size[0] * transform.scale[0] * 0.5, collider.size[1] * transform.scale[1] * 0.5, mask)
		world.box2d_bodies[entity] = native
	} else if collider, has_collider := world.circle_colliders_2d[entity]; has_collider {
		scale := transform.scale[0] if transform.scale[0] > transform.scale[1] else transform.scale[1]
		native := create_box2d_body_id(world, body, transform.position[0], transform.position[1])
		create_box2d_circle_shape(native, collider.radius * scale, mask)
		world.box2d_bodies[entity] = native
	}
}

create_box2d_static :: proc(world: ^World, entity: Entity) {
	transform, found := get_transform(world, entity); collider, has_collider := world.box_colliders_2d[entity]
	if !found || !has_collider { return }
	mask, _ := entity_layer_mask(world, entity)
	body := create_box2d_body_id(world, RigidBody2D{gravity_scale = 0, body_type = "static"}, transform.position[0], transform.position[1])
	create_box2d_box_shape(body, collider.size[0] * transform.scale[0] * 0.5, collider.size[1] * transform.scale[1] * 0.5, mask)
	world.box2d_bodies[entity] = body
}

create_circle2d_static :: proc(world: ^World, entity: Entity) {
	transform, found := get_transform(world, entity); collider, has_collider := world.circle_colliders_2d[entity]
	if !found || !has_collider { return }
	mask, _ := entity_layer_mask(world, entity)
	scale := transform.scale[0] if transform.scale[0] > transform.scale[1] else transform.scale[1]
	body := create_box2d_body_id(world, RigidBody2D{gravity_scale = 0, body_type = "static"}, transform.position[0], transform.position[1])
	create_box2d_circle_shape(body, collider.radius * scale, mask)
	world.box2d_bodies[entity] = body
}

sync_bodies_from_box2d :: proc(world: ^World) {
	for entity, &body in world.rigid_bodies_2d {
		native, found := world.box2d_bodies[entity]
		if !found { continue }
		transform, has_transform := get_transform(world, entity)
		if !has_transform { continue }
		position := b2.Body_GetPosition(native)
		velocity := b2.Body_GetLinearVelocity(native)
		transform.position[0] = position.x
		transform.position[1] = position.y
		body.velocity[0] = velocity.x
		body.velocity[1] = velocity.y
		body.grounded = box2d_is_grounded(native)
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

create_box2d_shape_def :: proc(layer_mask: u64) -> b2.ShapeDef {
	def := b2.DefaultShapeDef()
	def.density = 1
	def.material.friction = 0.6
	def.filter.categoryBits = layer_mask
	def.filter.maskBits = layer_mask
	return def
}

create_box2d_box_shape :: proc(body: b2.BodyId, half_width, half_height: f32, layer_mask: u64) {
	def := create_box2d_shape_def(layer_mask)
	shape := b2.MakeBox(half_width, half_height)
	_ = b2.CreatePolygonShape(body, def, &shape)
}

create_box2d_circle_shape :: proc(body: b2.BodyId, radius: f32, layer_mask: u64) {
	def := create_box2d_shape_def(layer_mask)
	shape := b2.Circle{radius = radius}
	_ = b2.CreateCircleShape(body, def, &shape)
}

box2d_is_grounded :: proc(body: b2.BodyId) -> bool {
	contacts: [16]b2.ContactData
	for contact in b2.Body_GetContactData(body, contacts[:]) {
		if contact.manifold.pointCount == 0 { continue }
		if b2.ID_EQUALS(b2.Shape_GetBody(contact.shapeIdA), body) {
			if contact.manifold.normal.y > 0.5 { return true }
		} else if contact.manifold.normal.y < -0.5 {
			return true
		}
	}
	return false
}

box2d_body_type :: proc(body_type: string) -> b2.BodyType {
	if body_type == "dynamic" { return .dynamicBody }
	if body_type == "kinematic" { return .kinematicBody }
	return .staticBody
}
